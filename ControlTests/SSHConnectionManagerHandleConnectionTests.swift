import Testing
import Foundation
@testable import Control

/// Exercises `SSHConnectionManager.handleConnection`'s dispatch — the routing
/// a host-key mismatch takes to `hostKeyMismatchHandler` (or `onError` when
/// none is installed), and how `trustedHostKeyProvider` reaches the transport
/// — via `transportFactory`, an injection seam that substitutes `FakeSSHClient`
/// for the real network transport. `FakeSSHClient`'s `connectResult`/
/// `lastTrustedFingerprints` were added for exactly this; previously nothing
/// exercised them, so this routing had no regression coverage at all.
@MainActor
struct SSHConnectionManagerHandleConnectionTests {

    private func makeManager(_ fakeClient: FakeSSHClient) -> SSHConnectionManager {
        let manager = SSHConnectionManager()
        manager.transportFactory = { _ in fakeClient }
        return manager
    }

    @Test func mismatchRoutesToTheInstalledHandlerNotOnError() async {
        let fakeClient = FakeSSHClient()
        let rejectedKey = SSHHostKeyInfo(fingerprint: "SHA256:evil", keyType: "ssh-ed25519")
        fakeClient.connectResult = .failure(SSHError.hostKeyMismatch(observed: rejectedKey))
        let manager = makeManager(fakeClient)

        let handled = await withCheckedContinuation { (continuation: CheckedContinuation<SSHHostKeyInfo, Never>) in
            manager.hostKeyMismatchHandler = { key in continuation.resume(returning: key) }
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { Issue.record("onSuccess should not fire on a mismatch") },
                onError: { _ in Issue.record("onError should not fire once a handler is installed") }
            )
        }

        #expect(handled.fingerprint == rejectedKey.fingerprint)
    }

    @Test func mismatchFallsThroughToOnErrorWithNoHandlerInstalled() async {
        let fakeClient = FakeSSHClient()
        let rejectedKey = SSHHostKeyInfo(fingerprint: "SHA256:evil", keyType: "ssh-ed25519")
        fakeClient.connectResult = .failure(SSHError.hostKeyMismatch(observed: rejectedKey))
        let manager = makeManager(fakeClient)
        // hostKeyMismatchHandler intentionally left nil.

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error, Never>) in
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { Issue.record("onSuccess should not fire on a mismatch") },
                onError: { error in continuation.resume(returning: error) }
            )
        }

        guard case SSHError.hostKeyMismatch(let observed) = error else {
            Issue.record("Expected hostKeyMismatch, got \(error)")
            return
        }
        #expect(observed.fingerprint == rejectedKey.fingerprint)
    }

    @Test func forwardsTheProvidersFingerprintsKeyedByHost() async {
        let fakeClient = FakeSSHClient()
        fakeClient.connectResult = .success(SSHHostKeyInfo(fingerprint: "SHA256:good", keyType: "ssh-ed25519"))
        let manager = makeManager(fakeClient)
        manager.trustedHostKeyProvider = { host in host == "test.local" ? ["SHA256:trusted-one"] : ["SHA256:wrong-host"] }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { continuation.resume() },
                onError: { error in
                    Issue.record("Expected success, got \(error)")
                    continuation.resume()
                }
            )
        }

        #expect(fakeClient.lastTrustedFingerprints == ["SHA256:trusted-one"])
    }

    @Test func forwardsAnEmptySetWithNoProviderInstalled() async {
        let fakeClient = FakeSSHClient()
        fakeClient.connectResult = .success(SSHHostKeyInfo(fingerprint: "SHA256:good", keyType: "ssh-ed25519"))
        let manager = makeManager(fakeClient)
        // trustedHostKeyProvider intentionally left nil.

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { continuation.resume() },
                onError: { error in
                    Issue.record("Expected success, got \(error)")
                    continuation.resume()
                }
            )
        }

        #expect(fakeClient.lastTrustedFingerprints.isEmpty)
    }
}
