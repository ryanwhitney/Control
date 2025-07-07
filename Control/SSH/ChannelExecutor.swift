import Foundation
import NIOSSH
import NIOCore

/// Utility function to add timeout to async operations
private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            return try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}

/// Actor responsible for running commands serially on the SSH connection.
/// It opens a NEW exec channel for every command (required by macOS sshd) but keeps
/// the overhead low by re-using the underlying TCP connection and serialising calls.
@available(iOS 15.0, *)
actor ChannelExecutor {
    private static let idQueue = DispatchQueue(label: "com.volumecontrol.executorIdQueue")
    private static var nextExecutorID = 1
    
    private let executorId: Int
    private unowned let connection: Channel
    private var shellChannel: Channel?
    private let shellHandler: StreamingShellHandler
    private let channelKey: String
    
    // MARK: - Single-flight queue support
    private struct WorkItem {
        let payload: String
        let sentinel: String
        let description: String?
        let continuation: CheckedContinuation<Result<String, Error>, Never>
    }

    private var workQueue: [WorkItem] = []
    private var isBusy = false
    private var commandCounter: UInt32 = 0
    
    // MARK: - Reliability tuning
    /// Maximum number of commands that can be queued when the executor is busy.
    /// This still keeps latency low (worst-case 2 in-flight before the one just issued)
    /// but avoids the "Executor busy" error when the user taps e.g. ▶︎ six times quickly.
    private let maxQueuedCommands = 6

    /// Number of consecutive timeouts observed.  We only tear the channel down after
    /// a small burst of timeouts to avoid over-aggressive reconnects on a momentary stall.
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 2

    /// Command watchdog duration.  AppleScript can legitimately take >2 s under load.
    private let commandTimeoutSeconds: TimeAmount = .seconds(3)
    
    init(connection: Channel, channelKey: String) {
        var id = 0
        ChannelExecutor.idQueue.sync {
            id = ChannelExecutor.nextExecutorID
            ChannelExecutor.nextExecutorID += 1
        }
        self.executorId = id
        
        sshLog("🔧 [E\(self.executorId)] ChannelExecutor: Initializing for key '\(channelKey)'")
        self.connection = connection
        self.channelKey = channelKey
        
        // Create a single interactive shell session
        let promise = connection.eventLoop.makePromise(of: Channel.self)
        let handler = StreamingShellHandler()
        self.shellHandler = handler
        connection.pipeline.handler(type: NIOSSHHandler.self)
            .flatMap { sshHandler -> EventLoopFuture<Channel> in
                sshHandler.createChannel(promise) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                    }
                    return child.pipeline.addHandlers([handler])
                }
                return promise.futureResult
            }
            .flatMap { (chan: Channel) -> EventLoopFuture<Void> in
                // Persist the channel reference as soon as it's available
                Task { [weak self] in
                    await self?.setShellChannel(chan)
                }
                // Always use the interactive AppleScript shell
                return setupInteractiveShell(channel: chan, command: "/usr/bin/osascript -s s -l AppleScript -i")
            }
            .whenComplete { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    sshLog("🔧 [E\(self.executorId)] ChannelExecutor: ✓ Interactive AppleScript ready")
                case .failure(let error):
                    sshLog("🔧 [E\(self.executorId)] ChannelExecutor: ❌ Failed to start interactive shell: \(error)")
                }
            }
    }
    
    /// Executes `command` by queueing it. Exactly one command is inflight on the interactive shell.
    func run(command: String, description: String?) async -> Result<String, Error> {
        // Respect the bounded queue: accept up to `maxQueuedCommands` items.
        if isBusy || !workQueue.isEmpty {
            if workQueue.count >= maxQueuedCommands {
                let dropPreview = description ?? String(command.prefix(30))
                sshLog("🔧 [E\(executorId):\(channelKey)] ⚠️ Queue full – rejecting cmd \(dropPreview)")
                return .failure(SSHError.channelError("Executor queue full"))
            }
        }

        // Build unique command id & sentinel
        let cmdId = commandCounter
        commandCounter &+= 1
        let cmdIdHex = String(format: "%04X", cmdId & 0xFFFF)
        let sentinel = ">>>VOLCTL_\(cmdIdHex)<<<"

        // AppleScript payload (command already wrapped upstream)
        let escapedSentinel = sentinel.replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "-- \(cmdIdHex) \(description ?? "")\n\(command)\n\n\"\(escapedSentinel)\"\n\n"

        let preview = description ?? String(command.prefix(40))
        sshLog("🔧 [E\(executorId):\(channelKey)] ⬆️ \(cmdIdHex) \(preview)")

        return await withCheckedContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(returning: .failure(SSHError.channelError("Executor deallocated")))
                return
            }
            Task { await self.enqueueWorkItem(payload: payload, sentinel: sentinel, description: description, continuation: continuation) }
        }
    }

    private func enqueueWorkItem(payload: String, sentinel: String, description: String?, continuation: CheckedContinuation<Result<String, Error>, Never>) async {
        let item = WorkItem(payload: payload, sentinel: sentinel, description: description, continuation: continuation)
        workQueue.append(item)
        await processNext()
    }

    // MARK: - Internal queue processor
    private func processNext() async {
        guard !isBusy, !workQueue.isEmpty else { return }
        guard let chan = await ensureShellChannelReady() else { return }

        let item = workQueue.removeFirst()
        isBusy = true

        // Prepare promise & sentinel mapping
        let promise = chan.eventLoop.makePromise(of: String.self)
        shellHandler.addCommand(sentinel: item.sentinel, promise: promise)

        // Send payload
        let buffer = chan.allocator.buffer(string: item.payload)
        chan.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)

        // Timeout watchdog – more generous and adaptive. We don't immediately kill the
        // channel on the first timeout to avoid expensive reconnects during short stalls.
        let timeoutTask = chan.eventLoop.scheduleTask(in: commandTimeoutSeconds) { [weak self] in
            guard let self else { return }
            sshLog("🔧 [E\(executorId)] ChannelExecutor: ⏰ Cmd \(item.sentinel.prefix(8)) timed out")
            promise.fail(SSHError.timeout)

            self.consecutiveTimeouts += 1

            if self.consecutiveTimeouts >= self.maxConsecutiveTimeouts {
                sshLog("🔧 [E\(executorId)] ChannelExecutor: ⚠️ Too many consecutive timeouts – closing shell channel")
                Task { await self.close() }
                self.consecutiveTimeouts = 0
            } else {
                // Allow queue to proceed; mark not busy to process next command
                Task { await self.finishCurrentAndContinue() }
            }
        }

        promise.futureResult.whenComplete { [weak self] result in
            timeoutTask.cancel()
            guard let self = self else { return }
            // Success or failure resets the timeout counter if we did get a response
            self.consecutiveTimeouts = 0
            let cont = item.continuation
            Task { @MainActor in
                cont.resume(returning: result)
            }
            Task { await self.finishCurrentAndContinue() }
        }
    }

    private func finishCurrentAndContinue() async {
        isBusy = false
        await processNext()
    }

    private func ensureShellChannelReady() async -> Channel? {
        var retries = 0
        while shellChannel == nil && retries < 150 {
            retries += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if shellChannel == nil {
            sshLog("🔧 [E\(executorId):\(channelKey)] ❌ No shell channel available")
        }
        return shellChannel
    }
    
    /// Close shell channel
    func close() {
        sshLog("🔧 [E\(executorId)] ChannelExecutor: Closing shell channel")
        if let chan = self.shellChannel {
            chan.close(promise: nil)
        }
    }
    
    /// Set shell channel from async context
    private func setShellChannel(_ channel: Channel) {
        self.shellChannel = channel
    }
}

// A simple passthrough error handler for the exec child channel.
private class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshLog("🔧 ErrorHandler: ❌ Error caught: \(error)")
        context.close(promise: nil)
    }
}

private func setupInteractiveShell(channel: Channel, command: String) -> EventLoopFuture<Void> {
    // First allocate a PTY for proper terminal behavior
    let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: true,
        term: "xterm-256color", 
        terminalCharacterWidth: 80,
        terminalRowHeight: 24,
        terminalPixelWidth: 0,
        terminalPixelHeight: 0,
        terminalModes: SSHTerminalModes([:])
    )
    
    return channel.triggerUserOutboundEvent(ptyRequest)
        .flatMap { _ -> EventLoopFuture<Void> in
            // Now request an interactive shell
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            return channel.triggerUserOutboundEvent(shellRequest)
        }
        .flatMap { _ -> EventLoopFuture<Void> in
            // Send the initial command to set up our specific interpreter
            let initialPayload = "\(command)\n"
            let buffer = channel.allocator.buffer(string: initialPayload)
            let writePromise = channel.eventLoop.makePromise(of: Void.self)
            channel.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: writePromise)
            return writePromise.futureResult
        }
        .flatMapError { error in
            print("🔧 setupInteractiveShell: ❌ Setup failed: \(error)")
            return channel.eventLoop.makeFailedFuture(error)
        }
} 
