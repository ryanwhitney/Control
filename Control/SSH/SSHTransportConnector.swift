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
        hostKeyDelegate.onReject = { error in
            attempt.finish(.failure(error)) {
                timeout.cancel()
                sshLog("❌ [\(connectionId)] Host key rejected: \(error)")
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
                        // opens, so observedInfo is guaranteed set here. If it
                        // somehow isn't, fail as a neutral connection error, not
                        // a changed-identity alarm.
                        guard let hostKeyInfo = hostKeyDelegate.observedInfo else {
                            attempt.finish(.failure(SSHError.connectionFailed("Could not verify the Mac's identity"))) {
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

    /// Reads the SSH host key a machine presents, without authenticating.
    /// The key exchange runs far enough for the server to prove possession of
    /// its host key, the fingerprint is recorded, and validation is then
    /// failed so the connection tears down before user authentication could
    /// begin — no credentials are ever offered. Returns nil on any failure
    /// (unreachable, timeout, unparseable key).
    ///
    /// Used to search for a pinned identity at another address after a
    /// mismatch. The result is trustworthy because only the holder of the
    /// host's private key can complete the exchange for its fingerprint.
    static func probeHostKey(host: String, timeout: TimeInterval = 4.0) async -> SSHHostKeyInfo? {
        await withCheckedContinuation { continuation in
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            probeHostKey(group: group, host: host, timeout: timeout) { info in
                group.shutdownGracefully { _ in }
                continuation.resume(returning: info)
            }
        }
    }

    private static func probeHostKey(
        group: EventLoopGroup,
        host: String,
        timeout: TimeInterval,
        completion: @escaping (SSHHostKeyInfo?) -> Void
    ) {
        let attempt = ProbeAttempt(completion)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            attempt.finish(nil)
        }

        let probeDelegate = HostKeyProbeDelegate()
        probeDelegate.onObserve = { info in
            attempt.finish(info)
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(3))
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: ProbeNoAuthDelegate(),
                        serverAuthDelegate: probeDelegate
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                ))
            }

        bootstrap.connect(host: host, port: 22).whenComplete { result in
            switch result {
            case .success(let channel):
                if !attempt.register(channel) {
                    channel.close(promise: nil)
                }
                // The probe delegate fails validation once it has the key, so
                // the channel closes itself; this covers handshake failures
                // that never reach validateHostKey.
                channel.closeFuture.whenComplete { _ in
                    attempt.finish(nil)
                }
            case .failure:
                attempt.finish(nil)
            }
        }
    }

    /// Once-only delivery for the probe, mirroring ConnectAttempt: whichever
    /// of observation / timeout / close fires first wins, and the channel is
    /// closed regardless of which path loses.
    private final class ProbeAttempt {
        private let lock = NSLock()
        private var completion: ((SSHHostKeyInfo?) -> Void)?
        private var channel: Channel?

        init(_ completion: @escaping (SSHHostKeyInfo?) -> Void) {
            self.completion = completion
        }

        func register(_ channel: Channel) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard completion != nil else { return false }
            self.channel = channel
            return true
        }

        func finish(_ info: SSHHostKeyInfo?) {
            lock.lock()
            let handler = completion
            completion = nil
            let held = channel
            channel = nil
            lock.unlock()

            guard let handler else { return }
            held?.close(promise: nil)
            handler(info)
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
    /// The key the server presented, computed during validation. Read on the
    /// success path to record what was pinned. Nil only if the key couldn't be
    /// parsed (an effectively unreachable internal failure).
    private(set) var observedInfo: SSHHostKeyInfo?
    /// Delivers the reason a key was rejected, called *before* the validation
    /// promise is failed so the caller's once-only result wins the race against
    /// NIOSSH's teardown (which would otherwise surface a generic connection
    /// error). Carries the error as a parameter so this delegate isn't captured
    /// by the caller's closure — capturing it would form a retain cycle.
    var onReject: ((SSHError) -> Void)?

    init(trustedFingerprints: Set<String>) {
        self.trustedFingerprints = trustedFingerprints
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let info = try? SSHHostKeyFingerprint.compute(for: hostKey) else {
            // NIOSSH already parsed this key during key exchange, so this is
            // effectively unreachable. Fail closed, but as a neutral connection
            // error — an internal parse failure, not a changed identity.
            onReject?(.connectionFailed("Could not read the Mac's identity"))
            validationCompletePromise.fail(SSHError.connectionFailed("Could not read the Mac's identity"))
            return
        }
        observedInfo = info

        // Empty set → trust-on-first-use; otherwise the presented key must be
        // one the user has already accepted for this host.
        if trustedFingerprints.isEmpty || trustedFingerprints.contains(info.fingerprint) {
            validationCompletePromise.succeed(())
            return
        }
        onReject?(.hostKeyMismatch(observed: info))
        validationCompletePromise.fail(SSHError.hostKeyMismatch(observed: info))
    }
}

/// Captures the host key presented during a probe's key exchange, then fails
/// validation so the connection ends before user authentication.
private final class HostKeyProbeDelegate: NIOSSHClientServerAuthenticationDelegate {
    var onObserve: ((SSHHostKeyInfo?) -> Void)?

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        onObserve?(try? SSHHostKeyFingerprint.compute(for: hostKey))
        validationCompletePromise.fail(SSHError.connectionFailed("Host key probe complete"))
    }
}

/// Never offers credentials. A probe's validation failure means auth is never
/// reached, but if it somehow were, this delegate declines to authenticate.
private final class ProbeNoAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(nil)
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
