import Foundation

protocol SSHClientProtocol {
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()
    func executeCommandWithNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void)
}

// Default implementation for optional description parameter
extension SSHClientProtocol {
    func executeCommandWithNewChannel(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommandWithNewChannel(command, description: nil, completion: completion)
    }
} 