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
///   • Bash is forced explicitly. sshd runs this exec request through the
///     account's *login* shell; an exotic one (fish is the recurring culprit)
///     mis-parses the `stty …; exec …` sequence or handles `exec` differently.
///     Re-exec'ing into `/bin/bash -c` first makes the setup POSIX-parsed on
///     every Mac — the same reason the legacy transport wraps commands in bash.
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
            // The whole setup is re-exec'd under bash so the login shell (which
            // sshd uses to run this request) can't mis-parse it — see the doc
            // comment above. `command` is a fixed internal literal with no single
            // quotes, so single-quoting it for bash is safe across fish/zsh/bash.
            let inner = "stty -echo -echoe -echok 2>/dev/null; exec \(command)"
            let wrapped = "exec /bin/bash -c '\(inner)'"
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: wrapped, wantReply: true)
            return channel.triggerUserOutboundEvent(execRequest)
        }
        .flatMapError { error in
            sshLog("☄︎ setupInteractiveShell: ❌ Setup failed: \(error)")
            return channel.eventLoop.makeFailedFuture(error)
        }
} 
