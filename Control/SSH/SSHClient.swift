import Foundation
import NIOSSH
import NIOCore
import NIOPosix

enum SSHError: Error {
    case channelNotConnected
    case invalidChannelType
    case authenticationFailed
    case connectionFailed(String)
    case timeout
    case channelError(String)
    case noSession
}

class SSHClient: SSHClientProtocol, @unchecked Sendable {
    private var group: EventLoopGroup

    /// Guards `connection` and `dedicatedExecutors`: both are touched from the
    /// unstructured `Task`s that `executeCommandOnDedicatedChannel` spawns, so
    /// concurrent first commands (e.g. volume + status on connect) would
    /// otherwise race the dictionary and can build two executors for one key.
    private let stateLock = NSLock()
    private var connection: Channel?

    // MARK: - Dedicated Channel Support
    // Using a single app channel improves stability by serialising all app commands.
    // This is why `serializesAppCommands` is true here (the protocol default): all
    // platform status/action commands funnel through one `app-0` executor, so a
    // bulk refresh queues behind itself — AppController refreshes visible-first.
    private let appChannelPoolSize = 1

    /// Executors keyed by physical channel name (e.g. "system", "app-0", "app-1")
    private var dedicatedExecutors: [String: ChannelExecutor] = [:]

    /// Retrieve an existing executor or create a new one based on the logical key.
    /// This function maps a logical key (like "spotify") to a physical executor (like "app-2").
    private func executor(for key: String) throws -> ChannelExecutor {
        let executorKey = physicalKey(for: key)

        stateLock.lock()
        defer { stateLock.unlock() }

        if let existing = dedicatedExecutors[executorKey] {
            return existing
        }

        // Ensure we have an active SSH TCP connection.
        guard let connection = self.connection else {
            sshLog("📡 SSHClient: ❌ No active connection for executor creation")
            throw SSHError.channelNotConnected
        }

        // Create a new ChannelExecutor for this physical key ("app-N" or "system")
        let executor = ChannelExecutor(connection: connection, channelKey: executorKey)
        dedicatedExecutors[executorKey] = executor
        sshLog("☕︎ Channel '\(executorKey)' ready")
        return executor
    }

    /// Async helper that runs a command on a dedicated channel and returns the Result.
    private func performOnDedicatedChannel(_ channelKey: String, command: String, description: String?) async -> Result<String, Error> {
        do {
            let exec = try executor(for: channelKey)
            let result = await exec.run(command: command, description: description)
            if case .failure(let error) = result {
                var shouldReset = false
                if case SSHError.timeout = error { shouldReset = true }
                if case SSHError.channelError = error { shouldReset = true }
                if shouldReset {
                    let physicalKey = self.physicalKey(for: channelKey)
                    // Evict under the lock via a synchronous helper: NSLock's
                    // lock()/unlock() are unavailable directly in an async context.
                    let evicted = evictExecutor(forKey: physicalKey)
                    if let evicted {
                        // Close, don't just drop: an evicted executor still holds a
                        // live PTY channel (and a remote osascript) otherwise.
                        await evicted.close()
                        sshLog("📡 SSHClient: Closed executor for key '\(physicalKey)' due to error – will recreate on next use")
                    }
                }
            }
            return result
        } catch {
            sshLog("❌ Failed to get executor or run command: \(error)")
            return .failure(error)
        }
    }

    /// Remove an executor from the pool under `stateLock`. Synchronous so the
    /// lock is never taken from an async context (a Swift 6 error).
    private func evictExecutor(forKey key: String) -> ChannelExecutor? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return dedicatedExecutors.removeValue(forKey: key)
    }

    // Protocol-facing entry point (completion-handler style)
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            let result = await performOnDedicatedChannel(channelKey, command: command, description: description)
            completion(result)
        }
    }

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        disconnect()
        try? group.syncShutdownGracefully()
    }

    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let connectionId = String(UUID().uuidString.prefix(8))
        sshLog("⚯ [\(connectionId)] SSHClient: Connecting to \(host) as \(username)")

        // Only clean up if we have an active connection
        stateLock.lock()
        let hadConnection = connection != nil
        stateLock.unlock()
        if hadConnection {
            sshLog("Cleaning up existing connection before reconnecting")
            disconnect()
        }

        SSHTransportConnector.connect(
            group: group,
            host: host,
            username: username,
            password: password,
            connectionId: connectionId,
            makeChildHandlers: { [ErrorHandler()] }
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let established):
                // The gate channel proved authentication; the PTY executors
                // open their own channels, so it isn't needed further.
                established.session.close(promise: nil)
                self.stateLock.lock()
                self.connection = established.connection
                self.stateLock.unlock()
                sshLog("☕︎ [\(connectionId)] SSH connection ready for channels")
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func disconnect() {
        sshLog("⚯ Starting disconnect process")

        stateLock.lock()
        let executors = dedicatedExecutors
        dedicatedExecutors.removeAll()
        let conn = connection
        connection = nil
        stateLock.unlock()

        // Close and clear any dedicated channels
        for (key, executor) in executors {
            sshLog("Closing dedicated channel for key: \(key)")
            Task { await executor.close() }
        }

        conn?.close(promise: nil)
        sshLog("⚰︎ SSHClient disconnected and cleaned up")
    }

    /// Maps a logical channel key ("system", "heartbeat", app id) to its underlying executor key.
    private func physicalKey(for logicalKey: String) -> String {
        if logicalKey == "system" { return "system" }
        if logicalKey == "heartbeat" { return "heartbeat" }
        return "app-\(abs(logicalKey.hashValue) % appChannelPoolSize)"
    }
}

private class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // This handler is for server-initiated channels, which we don't expect.
        // Logging the error is sufficient.
        sshLog("SSH Error on server-initiated channel: \(error)")
        context.close(promise: nil)
    }
}
