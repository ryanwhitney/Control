import Foundation
import NIOSSH
import NIOCore

/// Actor that serialises AppleScript commands on a dedicated SSH *child-channel*.
/// For each physical key (`system`, `heartbeat`, `app-0`, …) we open an interactive
/// session – a PTY running `/usr/bin/osascript -s s -l AppleScript -i` and keep it
/// alive for the lifetime of the executor.  Every command is streamed into that
/// interpreter, demarcated with a unique sentinel so responses can be matched back
/// to their promises.  If a fatal timeout or channel error occurs the shell is
/// closed and the executor will be recreated on next use.
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
    
    // Warm-up flag – we send a no-op AppleScript (`return 0`) once per channel
    // before the very first real command to make sure the interpreter has
    // finished its prompt/initialisation handshake.  This greatly reduces the
    // likelihood of the first user command timing out.
    private var isWarmedUp = false
    
    // MARK: - Reliability tuning
    /// Maximum number of commands that can be queued when the executor is busy.
    /// This still keeps latency low (worst-case 2 in-flight before the one just issued)
    /// but avoids the "Executor busy" error when the user taps e.g. ▶︎ six times quickly.
    private let maxQueuedCommands = 20

    /// Number of consecutive timeouts observed.  We only tear the channel down after
    /// a small burst of timeouts to avoid over-aggressive reconnects on a momentary stall.
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 1

    /// Command watchdog duration.  AppleScript can legitimately take >2 s under load.
    private let commandTimeoutSeconds: TimeAmount = .seconds(3)
    
    init(connection: Channel, channelKey: String) {
        var id = 0
        ChannelExecutor.idQueue.sync {
            id = ChannelExecutor.nextExecutorID
            ChannelExecutor.nextExecutorID += 1
        }
        self.executorId = id
        
        // Initialization logging handled by SSHClient
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
                case .success: break
                case .failure(let error):
                    sshLog("☄︎ [E\(self.executorId)] ChannelExecutor: ❌ Failed to start interactive shell: \(error)")
                }
            }
    }
    
    /// Executes `command` by queueing it. Exactly one command is inflight on the interactive shell.
    func run(command: String, description: String?) async -> Result<String, Error> {
        // Perform a one-time warm-up if this is the first command on the channel.
        if !isWarmedUp && channelKey != "system" {
            // Mark as warmed-up immediately to avoid recursion.
            isWarmedUp = true
            // Fire a synchronous warm-up round-trip and ignore the result.
            _ = await run(command: "return 0", description: "warm-up")
            // After the warm-up completes, proceed with the actual command below.
        }

        // Respect the bounded queue: accept up to `maxQueuedCommands` items.
        if isBusy || !workQueue.isEmpty {
            if workQueue.count >= maxQueuedCommands {
                let dropPreview = description ?? String(command.prefix(30))
                sshLog("☄︎ [E\(executorId):\(channelKey)] ⚠️ Queue full – rejecting cmd \(dropPreview)")
                return .failure(SSHError.channelError("Executor queue full"))
            }
        }

        // Build unique command id & sentinel
        let cmdId = commandCounter
        commandCounter &+= 1
        let cmdIdHex = String(format: "%04X", cmdId & 0xFFFF)
        let sentinel = ">>>CTRL_\(cmdIdHex)<<<"

        // AppleScript payload (command already wrapped upstream)
        let escapedSentinel = sentinel.replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "-- \(cmdIdHex) \(description ?? "")\n\(command)\n\n\"\(escapedSentinel)\"\n\n"

        // Only log command attempts on failure; success logged by AppController

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
            sshLog("☄︎ [E\(executorId)] ChannelExecutor: ⏰ Cmd \(item.sentinel.prefix(8)) timed out")
            promise.fail(SSHError.timeout)

            self.consecutiveTimeouts += 1

            if self.consecutiveTimeouts >= self.maxConsecutiveTimeouts {
                sshLog("☄︎ [E\(executorId)] ChannelExecutor: ⚠️ Too many consecutive timeouts – closing shell channel")
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
            sshLog("☄︎ [E\(executorId):\(channelKey)] ❌ No shell channel available")
        }
        return shellChannel
    }
    
    /// Close shell channel
    func close() {
        sshLog("☄︎ [E\(executorId)] ChannelExecutor: Closing shell channel")
        if let chan = self.shellChannel {
            chan.close(mode: .all, promise: nil)
        }
        // Reset internal state so this executor cannot be reused accidentally
        self.shellChannel = nil
        self.workQueue.removeAll()
        self.isBusy = false
    }
    
    /// Set shell channel from async context
    private func setShellChannel(_ channel: Channel) {
        self.shellChannel = channel
    }
} 
