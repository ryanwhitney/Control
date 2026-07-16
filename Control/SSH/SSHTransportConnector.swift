import Foundation
import NIOSSH
import NIOCore
import NIOPosix

/// Shared connect sequence for both SSH transports:
///
/// 1. TCP connect (4 s NIO connect timeout inside a 5 s overall watchdog).
/// 2. Open one SSH *session* child channel. NIOSSH only completes child-channel
///    creation after user authentication, so success here means
///    "authenticated", not merely "TCP is up" — a wrong password fails fast via
///    `PasswordAuthDelegate` instead of being reported as a successful
///    connection that dies on first use.
///
/// The streaming client closes the gate channel (its PTY executors open their
/// own); the legacy client keeps it as its long-lived session.
enum SSHTransportConnector {

    struct Established {
        let connection: Channel
        let session: Channel
        let hostKeyInfo: SSHHostKeyInfo
    }

    static func connect(
        group: EventLoopGroup,
        host: String,
        username: String,
        password: String,
        trustedHostKeyFingerprints: Set<String>,
        connectionId: String,
        makeChildHandlers: @escaping () -> [ChannelHandler],
        completion: @escaping (Result<Established, Error>) -> Void
    ) {
        // Exactly one result is delivered no matter which of the watchdog /
        // auth-failure / TCP / session paths fires first (they run on different
        // threads: main queue vs. the NIO event loop).
        let attempt = ConnectAttempt(completion)

        let timeout = DispatchWorkItem {
            attempt.finish(.failure(SSHError.timeout)) {
                sshLog("❌ [\(connectionId)] Connection timed out after 5 seconds")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)

        let authDelegate = PasswordAuthDelegate(username: username, password: password)
        authDelegate.onAuthFailure = {
            attempt.finish(.failure(SSHError.authenticationFailed)) {
                timeout.cancel()
                sshLog("❌ [\(connectionId)] Authentication failed")
            }
        }

        let hostKeyDelegate = HostKeyPinningDelegate(trustedFingerprints: trustedHostKeyFingerprints)
        hostKeyDelegate.onMismatch = {
            attempt.finish(.failure(SSHError.hostKeyMismatch(observed: hostKeyDelegate.observedInfo))) {
                timeout.cancel()
                sshLog("❌ [\(connectionId)] Host key mismatch")
            }
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(4)) // shorter than the 5 s watchdog
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: hostKeyDelegate
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        return childChannel.pipeline.addHandlers(makeChildHandlers())
                    }
                ))
            }

        bootstrap.connect(host: host, port: 22).whenComplete { result in
            switch result {
            case .success(let connection):
                sshLog("⚭ [\(connectionId)] TCP connection established")
                guard attempt.register(connection) else {
                    // Watchdog or auth failure already reported — don't leak the socket.
                    connection.close(promise: nil)
                    return
                }
                openSessionChannel(on: connection, makeChildHandlers: makeChildHandlers) { sessionResult in
                    switch sessionResult {
                    case .success(let session):
                        // validateHostKey always runs before a child channel
                        // opens, so observedInfo is guaranteed set here.
                        guard let hostKeyInfo = hostKeyDelegate.observedInfo else {
                            attempt.finish(.failure(SSHError.hostKeyMismatch(observed: nil))) {
                                timeout.cancel()
                                sshLog("❌ [\(connectionId)] Session opened without an observed host key")
                            }
                            session.close(promise: nil)
                            return
                        }
                        let delivered = attempt.finish(.success(Established(connection: connection, session: session, hostKeyInfo: hostKeyInfo))) {
                            timeout.cancel()
                        }
                        if !delivered {
                            // Lost the race against the watchdog/auth failure,
                            // which already closed the registered connection.
                            session.close(promise: nil)
                        }
                    case .failure(let error):
                        attempt.finish(.failure(SSHError.classify(error))) {
                            timeout.cancel()
                            sshLog("❌ [\(connectionId)] Session creation failed: \(error)")
                        }
                    }
                }
            case .failure(let error):
                attempt.finish(.failure(SSHError.classify(error))) {
                    timeout.cancel()
                    sshLog("❌ [\(connectionId)] TCP connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func openSessionChannel(
        on connection: Channel,
        makeChildHandlers: @escaping () -> [ChannelHandler],
        completion: @escaping (Result<Channel, Error>) -> Void
    ) {
        let promise = connection.eventLoop.makePromise(of: Channel.self)
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler -> EventLoopFuture<Channel> in
            handler.createChannel(promise) { channel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return channel.pipeline.addHandlers(makeChildHandlers())
            }
            return promise.futureResult
        }.whenComplete(completion)
    }

    /// Thread-safe once-only result delivery plus custody of the TCP channel,
    /// so whichever path loses the completion race can still close it.
    private final class ConnectAttempt {
        private let lock = NSLock()
        private var completion: ((Result<Established, Error>) -> Void)?
        private var connection: Channel?

        init(_ completion: @escaping (Result<Established, Error>) -> Void) {
            self.completion = completion
        }

        /// Records the live TCP channel. Returns false when the attempt already
        /// finished (the caller must close the channel itself).
        func register(_ channel: Channel) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard completion != nil else { return false }
            connection = channel
            return true
        }

        /// Delivers `result` unless one was already delivered; on failure also
        /// closes the registered TCP channel. `onDeliver` (logging, watchdog
        /// cancellation) runs only for the winning call. Returns whether this
        /// call won.
        @discardableResult
        func finish(_ result: Result<Established, Error>, onDeliver: () -> Void = {}) -> Bool {
            lock.lock()
            let handler = completion
            completion = nil
            let channel = connection
            connection = nil
            lock.unlock()

            guard let handler else { return false }
            if case .failure = result {
                channel?.close(promise: nil)
            }
            onDeliver()
            handler(result)
            return true
        }
    }
}

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var authAttempts = 0
    private(set) var authFailed = false
    var onAuthFailure: (() -> Void)?

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Only attempt password auth if it's available
        if !availableMethods.contains(.password) {
            sshLog("Password authentication not available on server")
            authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }

        // A second challenge means the server rejected our password. Offering
        // it again would just loop until the server's MaxAuthTries closes the
        // connection with a generic error — fail fast as an auth failure so the
        // user is asked to re-enter credentials.
        authAttempts += 1
        guard authAttempts == 1 else {
            sshLog("Password rejected by server")
            authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }

        sshLog("Attempting password authentication")
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

/// Pins the Mac's SSH host key across connections. `trustedFingerprints` is
/// the set of keys the user has already accepted for this host (from
/// `SavedConnections`). Following the `known_hosts` model, a key is accepted
/// if it's in that set — a Mac that legitimately presents more than one host
/// key (e.g. across an OS update that changes the negotiated key type) won't
/// false-alarm once each key has been confirmed. An *empty* set means the
/// host has never been pinned, so the presented key is trust-on-first-use.
/// A non-empty set that doesn't contain the presented key is rejected: the
/// identity changed since we last saw it — a benign reason (reinstalled
/// macOS, new Mac same name) or a spoofed device on the network — which the
/// caller surfaces as `SSHError.hostKeyMismatch` for the user to decide on.
final class HostKeyPinningDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let trustedFingerprints: Set<String>
    /// Set synchronously before either promise outcome — always populated
    /// once `validateHostKey` has run, whether accepted or rejected. The
    /// mismatch/retry flow needs the *rejected* key too, to add it to the
    /// trusted set if the user consciously chooses to trust it.
    private(set) var observedInfo: SSHHostKeyInfo?
    var onMismatch: (() -> Void)?

    init(trustedFingerprints: Set<String>) {
        self.trustedFingerprints = trustedFingerprints
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let info = try? SSHHostKeyFingerprint.compute(for: hostKey) else {
            // NIOSSH already parsed this key during key exchange, so this is
            // effectively unreachable — fail closed rather than silently
            // accept an unparseable identity.
            validationCompletePromise.fail(SSHError.hostKeyMismatch(observed: nil))
            onMismatch?()
            return
        }
        observedInfo = info

        // Empty set → trust-on-first-use; otherwise the presented key must be
        // one the user has already accepted for this host.
        if trustedFingerprints.isEmpty || trustedFingerprints.contains(info.fingerprint) {
            validationCompletePromise.succeed(())
            return
        }
        validationCompletePromise.fail(SSHError.hostKeyMismatch(observed: info))
        onMismatch?()
    }
}

/// Logs and closes on errors from server-initiated channels, which neither
/// transport expects. Shared by both transports' pipelines.
final class SSHChannelErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshLog("SSH Error on server-initiated channel: \(error)")
        context.close(promise: nil)
    }
}
