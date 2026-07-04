import NIOSSH
import NIOCore

// MARK: - ChannelExecutor shell helpers & error handler

/// Interactive AppleScript shell initialisation.
///
/// Allocates a PTY and **exec**s `osascript -i` directly. Key points, each
/// verified against real SSH-to-osascript captures on this platform:
///   • PTY is required — without a tty, `osascript -i` block-buffers its stdout
///     and nothing streams back per command.
///   • Exec (not a login shell) avoids the interactive shell rc entirely — no
///     greeting, no `ryan@` prompt, and crucially no blocking passphrase prompt
///     that a login shell's startup can raise and which would swallow input.
///   • `SSHTerminalModes([:])` (empty) — passing ECHO opcodes here caused the
///     channel to go silent (100% command timeouts); empty modes work.
///   • Echo is disabled with `stty -echo` *inside* the exec command instead, so
///     the AppleScript we stream isn't reflected into the output we parse.
/// `osascript -i` still prints `>> ` prompts, which the parser strips.
func setupInteractiveShell(channel: Channel, command: String) -> EventLoopFuture<Void> {
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
            // Quiet echo, then hand the PTY to osascript. `exec` replaces the
            // shell so osascript is the PTY's foreground process for streaming.
            let wrapped = "stty -echo -echoe -echok 2>/dev/null; exec \(command)"
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: wrapped, wantReply: true)
            return channel.triggerUserOutboundEvent(execRequest)
        }
        .flatMapError { error in
            sshLog("☄︎ setupInteractiveShell: ❌ Setup failed: \(error)")
            return channel.eventLoop.makeFailedFuture(error)
        }
} 
