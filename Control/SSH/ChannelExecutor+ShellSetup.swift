import NIOSSH
import NIOCore

// MARK: - ChannelExecutor shell helpers & error handler

/// Interactive AppleScript shell initialisation.
/// Allocates a PTY and launches `/usr/bin/osascript -i` so subsequent payloads can be streamed.
func setupInteractiveShell(channel: Channel, command: String) -> EventLoopFuture<Void> {
    // Allocate a PTY for proper terminal behaviour
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
            // Start an interactive shell session
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            return channel.triggerUserOutboundEvent(shellRequest)
        }
        .flatMap { _ -> EventLoopFuture<Void> in
            // Inject the AppleScript interpreter command
            let initialPayload = "\(command)\n"
            let buffer = channel.allocator.buffer(string: initialPayload)
            let writePromise = channel.eventLoop.makePromise(of: Void.self)
            channel.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: writePromise)
            return writePromise.futureResult
        }
        .flatMapError { error in
            sshLog("🔧 setupInteractiveShell: ❌ Setup failed: \(error)")
            return channel.eventLoop.makeFailedFuture(error)
        }
} 