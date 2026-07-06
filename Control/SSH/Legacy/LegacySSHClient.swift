import Foundation
import NIOSSH
import NIOCore
import NIOPosix

/// **Compatibility transport.** Opens a fresh SSH channel and runs one
/// `osascript` per command — no PTY, no persistent interpreter, no sentinels.
/// Selectable in Preferences (and used as an auto-fallback) for Macs where the
/// streaming transport misbehaves.
///
/// Conforms to `SSHClientProtocol` by ignoring `channelKey` and bash-wrapping the
/// raw AppleScript (`AppController` sends the same raw scripts to both transports;
/// only the framing/execution differs). The connect sequence, auth handling, and
/// error classification are shared with the streaming client via
/// `SSHTransportConnector` / `SSHError.classify`, so they are not redeclared here.
class LegacySSHClient: SSHClientProtocol {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?
    private let commandGate = CommandGate(maxInFlight: 5)

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        disconnect()
        try? group.syncShutdownGracefully()
    }

    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let connectionId = String(UUID().uuidString.prefix(8))
        sshLog("🆔 [\(connectionId)] LegacySSHClient: Starting connection process")

        if connection != nil {
            sshLog("Cleaning up existing connection before reconnecting")
            disconnect()
        }

        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        sshLog("Attempting TCP connection: \(connectionType)")

        SSHTransportConnector.connect(
            group: group,
            host: host,
            username: username,
            password: password,
            connectionId: connectionId,
            makeChildHandlers: { [SSHCommandHandler(), SSHChannelErrorHandler()] }
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let established):
                // Keep the auth-gating session channel as the long-lived session.
                self.connection = established.connection
                self.session = established.session
                sshLog("✓ [\(connectionId)] SSH connection fully established")
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - SSHClientProtocol

    /// Each command opens its own channel and runs concurrently, so a bulk
    /// status refresh doesn't queue behind itself — unlike the streaming transport.
    var serializesAppCommands: Bool { false }

    /// The streaming transport reuses channels keyed by `channelKey`; the legacy
    /// transport ignores it (fresh channel per command) via the shared
    /// `EphemeralCommandChannel`.
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // The heartbeat is the health signal — it must never queue behind a
        // status sweep, so it bypasses the gate (worst case 5 + 1 sessions,
        // still well under sshd's MaxSessions).
        if channelKey == "heartbeat" {
            runOnEphemeralChannel(command, description: description, completion: completion)
            return
        }
        commandGate.run { [weak self] finished in
            guard let self else {
                finished()
                completion(.failure(SSHError.channelNotConnected))
                return
            }
            self.runOnEphemeralChannel(command, description: description) { result in
                finished()
                completion(result)
            }
        }
    }

    private func runOnEphemeralChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        EphemeralCommandChannel.run(
            command,
            on: connection,
            description: description,
            onConnectionLoss: { [weak self] in self?.disconnect() },
            completion: completion
        )
    }

    func disconnect() {
        if let session = session {
            let exitRequest = SSHChannelRequestEvent.ExecRequest(command: "exit", wantReply: false)
            _ = session.triggerUserOutboundEvent(exitRequest)
            session.pipeline.handler(type: SSHCommandHandler.self).whenSuccess { handler in
                handler.pendingCommandPromise?.fail(SSHError.channelError("Connection closed"))
            }
        }

        session?.close(promise: nil)
        session = nil
        connection?.close(promise: nil)
        connection = nil
        sshLog("⚰︎ LegacySSHClient disconnected and cleaned up")
    }
}
