import Foundation
import NIOSSH
import NIOCore
import os

/// Actor that serialises AppleScript commands on a dedicated SSH *child-channel*.
/// For each physical key (`system`, `heartbeat`, `app-0`, …) we open an interactive
/// session – a PTY running `/usr/bin/osascript -s s -l AppleScript -i` and keep it
/// alive for the lifetime of the executor.  Every command is streamed into that
/// interpreter, demarcated with a unique sentinel so responses can be matched back
/// to their promises.  If a fatal timeout or channel error occurs the shell is
/// closed and the executor will be recreated on next use.
@available(iOS 16.0, *) // OSAllocatedUnfairLock requires iOS 16
actor ChannelExecutor {
    /// Monotonic executor id for logging. Guarded by a lock rather than a
    /// `DispatchQueue.sync` so it can be assigned from async contexts without
    /// the "unsafeForcedSync called from Swift Concurrent context" warning.
    private static let idCounter = OSAllocatedUnfairLock(initialState: 1)
    
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
    private let maxConsecutiveTimeouts = 2

    /// Command watchdog duration.  AppleScript can legitimately take >2 s under load.
    private let commandTimeoutSeconds: TimeAmount = .seconds(6)
    
    init(connection: Channel, channelKey: String) {
        self.executorId = ChannelExecutor.idCounter.withLock { next in
            let value = next
            next += 1
            return value
        }
        
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
    func stripSpacesAndEmptyLines(_ input: String) -> String {
        return input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
        let cleanCommand = stripSpacesAndEmptyLines(command)
        // Build unique command id & sentinel
        let cmdId = commandCounter
        commandCounter &+= 1
        let cmdIdHex = String(format: "%04X", cmdId & 0xFFFF)
        let sentinel = ScriptTokens.sentinel(cmdId)

        // The sentinel is [A-Z0-9_] only, so it needs no escaping inside the
        // AppleScript string literal appended after the command.
        let payload = "-- \(cmdIdHex) \(description ?? "")\n\(cleanCommand)\n\n\"\(sentinel)\"\n\n"
        
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
        guard let chan = await ensureShellChannelReady() else {
            // Channel never became ready — fail everything queued so callers
            // don't hang forever on a continuation that would never resume.
            // The channelError makes SSHClient drop and recreate this executor.
            let pending = workQueue
            workQueue.removeAll()
            for item in pending {
                let cont = item.continuation
                Task { @MainActor in cont.resume(returning: .failure(SSHError.channelError("Shell channel unavailable"))) }
            }
            return
        }

        let item = workQueue.removeFirst()
        isBusy = true

        // Capture immutable locals so the event-loop closures never touch actor
        // state or the (event-loop-confined) handler off its own loop.
        let handler = shellHandler
        let eid = executorId
        let key = channelKey
        let sentinel = item.sentinel
        let payload = item.payload
        let promise = chan.eventLoop.makePromise(of: String.self)

        // Register the pending command and write its payload atomically on the
        // event loop: the handler is only mutated on its own loop, and the
        // sentinel is registered before any response bytes can arrive.
        chan.eventLoop.execute {
            handler.addCommand(sentinel: sentinel, promise: promise)
            let buffer = chan.allocator.buffer(string: payload)
            chan.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }

        // Watchdog: on timeout, remove + fail *this* pending on the event loop so
        // a stale head can never misroute the next command (the old desync bug).
        let timeoutTask = chan.eventLoop.scheduleTask(in: commandTimeoutSeconds) {
            sshLog("☄︎ [E\(eid):\(key)] ⏰ Cmd \(sentinel.prefix(12)) timed out")
            handler.failCommand(sentinel: sentinel, error: SSHError.timeout)
        }

        promise.futureResult.whenComplete { [weak self] result in
            timeoutTask.cancel()
            let cont = item.continuation
            Task { @MainActor in cont.resume(returning: result) }
            Task { await self?.finish(result: result) }
        }
    }

    /// Post-command bookkeeping: count consecutive timeouts, tear the channel
    /// down after a small burst, otherwise process the next queued command.
    private func finish(result: Result<String, Error>) async {
        if case .failure(let error) = result, case SSHError.timeout = error {
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= maxConsecutiveTimeouts {
                sshLog("☄︎ [E\(executorId):\(channelKey)] ⚠️ \(consecutiveTimeouts) consecutive timeouts – closing shell channel")
                consecutiveTimeouts = 0
                close()
                return
            }
        } else {
            consecutiveTimeouts = 0
        }
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
        // Fail any not-yet-started work so awaiting callers don't hang forever.
        // (The in-flight command, if any, is resolved separately by its promise.)
        let pendingWork = workQueue
        workQueue.removeAll()
        for item in pendingWork {
            let cont = item.continuation
            Task { @MainActor in cont.resume(returning: .failure(SSHError.channelError("Executor closed"))) }
        }
        // Reset internal state so this executor cannot be reused accidentally.
        self.shellChannel = nil
        self.isBusy = false
    }
    
    /// Set shell channel from async context
    private func setShellChannel(_ channel: Channel) {
        self.shellChannel = channel
    }
} 
