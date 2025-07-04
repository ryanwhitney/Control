import Foundation
import NIOSSH
import NIOCore

/// Actor responsible for running commands serially on the SSH connection.
/// It opens a NEW exec channel for every command (required by macOS sshd) but keeps
/// the overhead low by re-using the underlying TCP connection and serialising calls.
@available(iOS 15.0, *)
actor ChannelExecutor {
    private unowned let connection: Channel
    private var shellChannel: Channel?
    private let shellHandler: StreamingShellHandler
    
    init(connection: Channel) {
        self.connection = connection
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
            .flatMap { [weak self] (chan: Channel) -> EventLoopFuture<Void> in
                // Persist the channel reference as soon as it's available
                self?.shellChannel = chan
                return makeShell(channel: chan)
            }
            .whenFailure { error in
                sshLog("❌ Failed to start interactive shell: \(error)")
            }
    }
    
    /// Executes `command` by opening a fresh exec channel on the existing SSH connection.
    /// The promise is fulfilled when the command finishes (or fails).
    func run(command: String, description: String?) async -> Result<String, Error> {
        // Ensure the interactive shell channel is ready. Wait up to 1 s (50 × 20 ms yields).
        var retries = 0
        while self.shellChannel == nil && retries < 50 {
            retries += 1
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }

        guard let chan = self.shellChannel else {
            return .failure(SSHError.noSession)
        }

        return await withCheckedContinuation { continuation in
            let sentinel = "__END__\(UUID().uuidString.prefix(6))__"
            let promise = chan.eventLoop.makePromise(of: String.self)
            self.shellHandler.addCommand(sentinel: sentinel, promise: promise)
            let payload = "\(command); printf '\n%s\n' \(sentinel)\n"
            var buffer = chan.allocator.buffer(string: payload)
            chan.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            promise.futureResult.whenComplete { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Close shell channel
    func close() {
        if let chan = self.shellChannel {
            chan.close(promise: nil)
        }
    }
}

// A simple passthrough error handler for the exec child channel.
private class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private func makeShell(channel: Channel) -> EventLoopFuture<Void> {
    let execReq = SSHChannelRequestEvent.ExecRequest(command: "/bin/sh -l", wantReply: true)
    return channel.triggerUserOutboundEvent(execReq)
} 
