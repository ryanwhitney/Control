import Foundation

protocol SSHClientProtocol {
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()
    /// Execute a command on a long-lived, dedicated SSH channel identified by `channelKey`.
    /// The same channel is reused for subsequent calls with the same key.
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void)

    /// True when app commands share one serial channel (streaming): callers
    /// should prefer refreshing only what's visible, since a bulk refresh would
    /// queue behind itself. False when each command gets its own channel
    /// (legacy), where a bulk refresh runs concurrently and is fine.
    var serializesAppCommands: Bool { get }
}

// Default implementation for optional description parameter
extension SSHClientProtocol {
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommandOnDedicatedChannel(channelKey, command, description: nil, completion: completion)
    }

    /// Streaming is the default transport and serialises app commands on one
    /// channel. Transports that open a channel per command override this.
    var serializesAppCommands: Bool { true }
}
