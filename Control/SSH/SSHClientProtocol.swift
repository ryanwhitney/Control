import Foundation

protocol SSHClientProtocol {
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()
    func executeCommandWithNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void)
    func executeCommandBypassingHeartbeat(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void)
    /// Execute a command on a long-lived, dedicated SSH channel identified by `channelKey`.
    /// The same channel is reused for subsequent calls with the same key.
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void)
}

// Default implementation for optional description parameter
extension SSHClientProtocol {
    func executeCommandWithNewChannel(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommandWithNewChannel(command, description: nil, completion: completion)
    }
    
    func executeCommandBypassingHeartbeat(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommandBypassingHeartbeat(command, description: nil, completion: completion)
    }
    
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommandOnDedicatedChannel(channelKey, command, description: nil, completion: completion)
    }
} 
