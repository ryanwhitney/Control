import Foundation
@testable import Control

/// In-memory `SSHClientProtocol` test double for driving `AppController` without
/// a real Mac or SSH. Records every command it receives and returns canned
/// AppleScript output via `responder`, so tests can assert both what the
/// controller *sent* (channel + script) and how it reacts to a given reply.
///
/// Nothing here connects: `connect`/`disconnect` are no-ops. Calls are recorded
/// and the completion is invoked synchronously, which is enough for
/// `AppController.executeCommand`'s `withCheckedContinuation` to resume in place.
final class FakeSSHClient: SSHClientProtocol {
    struct Call: Equatable {
        let channelKey: String
        let command: String
        let description: String?
    }

    /// Every `executeCommandOnDedicatedChannel` call, in order.
    private(set) var calls: [Call] = []

    /// Maps an incoming `(channelKey, command)` to the reply the controller sees.
    /// Defaults to an empty success so unconfigured channels don't crash a test.
    var responder: (_ channelKey: String, _ command: String) -> Result<String, Error> = { _, _ in .success("") }

    /// Mirrors the transport capability that steers `AppController`'s refresh
    /// strategy; defaults to the streaming value so tests get that path.
    var serializesAppCommands: Bool = true

    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func disconnect() {}

    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        calls.append(Call(channelKey: channelKey, command: command, description: description))
        completion(responder(channelKey, command))
    }

    // MARK: - Convenience for assertions

    /// Commands recorded for a given channel, in order.
    func commands(on channelKey: String) -> [String] {
        calls.filter { $0.channelKey == channelKey }.map { $0.command }
    }
}
