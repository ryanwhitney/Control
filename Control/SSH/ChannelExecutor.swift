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
    private unowned let connection: Channel
    private var shellChannel: Channel?
    private let shellHandler: StreamingShellHandler
    private let interactiveAppleScript: Bool
    
    init(connection: Channel, interactiveAppleScript: Bool) {
        print("🔧 ChannelExecutor: Initializing \(interactiveAppleScript ? "AppleScript" : "shell") executor")
        self.connection = connection
        self.interactiveAppleScript = interactiveAppleScript
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
                if interactiveAppleScript {
                    return setupInteractiveShell(channel: chan, command: "/usr/bin/osascript -s s -l AppleScript -i")
                } else {
                    return setupInteractiveShell(channel: chan, command: "/bin/sh -l")
                }
            }
            .whenComplete { result in
                switch result {
                case .success:
                    print("🔧 ChannelExecutor: ✓ Interactive \(interactiveAppleScript ? "AppleScript" : "shell") ready")
                    // Send test ping to verify the interactive session is working
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000) // Wait 500ms for shell to stabilize
                        await self?.sendTestPing()
                    }
                case .failure(let error):
                    print("🔧 ChannelExecutor: ❌ Failed to start interactive shell: \(error)")
                }
            }
    }
    
    /// Send a simple test command to verify the interactive session is responsive
    private func sendTestPing() async {
        guard let channel = shellChannel else {
            print("🔧 ChannelExecutor: No shell channel for test ping")
            return
        }
        
        let testSentinel = ">>>VOLCTL_PING_\(UUID().uuidString.prefix(4))<<<"
        let testPayload: String
        
        if interactiveAppleScript {
            testPayload = "1 + 1\n\n\"\(testSentinel)\"\n\n"
        } else {
            testPayload = "echo 'test-ok'; printf '\\n%s\\n' \(testSentinel)\n"
        }
        
        // Set up the test command in the handler
        let promise = channel.eventLoop.makePromise(of: String.self)
        self.shellHandler.addCommand(sentinel: testSentinel, promise: promise)
        
        // Send the test payload
        let buffer = channel.allocator.buffer(string: testPayload)
        channel.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        
        // Wait for the test result with a timeout
        do {
            _ = try await withTimeout(seconds: 3.0) {
                return try await promise.futureResult.get()
            }
            // Test ping successful - no need to log
        } catch {
            print("🔧 ChannelExecutor: ❌ Test ping failed: \(error)")
        }
    }
    
    /// Executes `command` by opening a fresh exec channel on the existing SSH connection.
    /// The promise is fulfilled when the command finishes (or fails).
    func run(command: String, description: String?) async -> Result<String, Error> {
        if let description = description {
            print("🔧 ChannelExecutor: \(description)")
        }
        
        // Ensure the interactive shell channel is ready. Wait up to 3s (150 × 20 ms yields).
        var retries = 0
        while self.shellChannel == nil && retries < 150 {
            retries += 1
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }

        guard let chan = self.shellChannel else {
            print("🔧 ChannelExecutor: ❌ No shell channel available")
            return .failure(SSHError.noSession)
        }
        
        // Give the interactive shell a moment to fully stabilize
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        return await withCheckedContinuation { continuation in
            let sentinelSuffix = String(UUID().uuidString.prefix(6))
            let sentinel = ">>>VOLCTL_END_\(sentinelSuffix)<<<"
            
            let promise = chan.eventLoop.makePromise(of: String.self)
            self.shellHandler.addCommand(sentinel: sentinel, promise: promise)
            
            let payload: String
            if self.interactiveAppleScript {
                // For interactive AppleScript, send the command, blank line to execute, then sentinel
                let escapedSentinel = sentinel.replacingOccurrences(of: "\"", with: "\\\"")
                payload = "\(command)\n\n\"\(escapedSentinel)\"\n\n"
                // Only log the description, not the full command
                if let desc = description {
                    print("🔧 ChannelExecutor: \(desc)")
                }
            } else {
                payload = "\(command); printf '\\n%s\\n' \(sentinel)\n"
            }
            
            let buffer = chan.allocator.buffer(string: payload)
            let writePromise = chan.eventLoop.makePromise(of: Void.self)
            chan.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: writePromise)
            
            // Add timeout to the promise
            let timeoutTask = chan.eventLoop.scheduleTask(in: .seconds(8)) {
                print("🔧 ChannelExecutor: ⏰ Command timed out after 8 seconds")
                promise.fail(SSHError.timeout)
            }
            
            promise.futureResult.whenComplete { result in
                timeoutTask.cancel()
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Close shell channel
    func close() {
        print("🔧 ChannelExecutor: Closing shell channel")
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
        print("🔧 ErrorHandler: ❌ Error caught: \(error)")
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
