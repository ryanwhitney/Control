import Foundation
import NIOSSH
import NIOCore
import NIOPosix

class SSHClient: SSHClientProtocol, @unchecked Sendable {
    private var group: EventLoopGroup

    /// Guards `connection` and `dedicatedExecutors`: both are touched from the
    /// unstructured `Task`s that `executeCommandOnDedicatedChannel` spawns, so
    /// concurrent first commands (e.g. volume + status on connect) would
    /// otherwise race the dictionary and can build two executors for one key.
    private let stateLock = NSLock()
    private var connection: Channel?

    /// Executors keyed by physical channel name (e.g. "system", "heartbeat", "app-0")
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
            // The executor self-heals from timeouts (it rebuilds its shell and
            // keeps its queue), so eviction only happens once it has permanently
            // given up — otherwise we'd destroy the surviving queue with it.
            if case .failure = result, await exec.isDefunct {
                let physicalKey = self.physicalKey(for: channelKey)
                // Evict under the lock via a synchronous helper: NSLock's
                // lock()/unlock() are unavailable directly in an async context.
                let evicted = evictExecutor(forKey: physicalKey)
                if let evicted {
                    // Close, don't just drop: an evicted executor could still hold
                    // a live PTY channel (and a remote osascript) otherwise.
                    await evicted.close()
                    sshLog("📡 SSHClient: Evicted defunct executor for key '\(physicalKey)' – will recreate on next use")
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

    /// Cap keeps ephemeral channels + the persistent ones (system, heartbeat,
    /// app-0) comfortably under sshd's MaxSessions (default 10).
    private let isolatedGate = CommandGate(maxInFlight: 4)

    /// Isolated commands bypass the shared interpreter entirely: each runs on
    /// its own throwaway exec channel, so one blocking (e.g. on a permission
    /// dialog) can't stall the serialized app channel or other isolated commands.
    func executeCommandIsolated(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        stateLock.lock()
        let conn = connection
        stateLock.unlock()
        guard let conn else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        isolatedGate.run { finished in
            EphemeralCommandChannel.run(command, on: conn, description: description) { result in
                finished()
                completion(result)
            }
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
            makeChildHandlers: { [SSHChannelErrorHandler()] }
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

    /// Maps a logical channel key ("system", "heartbeat", app id) to its underlying
    /// executor key. All app keys share the single "app-0" executor: serialising app
    /// commands on one channel improves stability, and is why `serializesAppCommands`
    /// is true here — a bulk refresh queues behind itself, so AppController refreshes
    /// visible-first.
    private func physicalKey(for logicalKey: String) -> String {
        if logicalKey == "system" { return "system" }
        if logicalKey == "heartbeat" { return "heartbeat" }
        return "app-0"
    }
}
