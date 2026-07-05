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
    }

    static func connect(
        group: EventLoopGroup,
        host: String,
        username: String,
        password: String,
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

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(4)) // shorter than the 5 s watchdog
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: AcceptAllHostKeysDelegate()
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
                        let delivered = attempt.finish(.success(Established(connection: connection, session: session))) {
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

class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Accept all host keys - in production, you should verify against known hosts
        validationCompletePromise.succeed(())
    }
}
