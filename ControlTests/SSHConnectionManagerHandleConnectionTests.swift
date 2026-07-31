import Testing
import Foundation
@testable import Control

/// Exercises `SSHConnectionManager.handleConnection`'s dispatch — the routing
/// a host-key mismatch takes to `hostKeyMismatchHandler` (or `onError` when
/// none is installed or the handler declines), and how `trustedHostKeyProvider`
/// reaches the transport — via `transportFactory`, an injection seam that
/// substitutes `FakeSSHClient` for the real network transport.
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

        let handled = await withCheckedContinuation { (continuation: CheckedContinuation<(String, SSHHostKeyInfo), Never>) in
            manager.hostKeyMismatchHandler = { host, key in
                continuation.resume(returning: (host, key))
                return true
            }
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { Issue.record("onSuccess should not fire on a mismatch") },
                onError: { _ in Issue.record("onError should not fire once a handler takes the mismatch") }
            )
        }

        #expect(handled.0 == "test.local")
        #expect(handled.1.fingerprint == rejectedKey.fingerprint)
    }

    @Test func mismatchTheHandlerDeclinesStillReachesOnError() async {
        let fakeClient = FakeSSHClient()
        let rejectedKey = SSHHostKeyInfo(fingerprint: "SHA256:evil", keyType: "ssh-ed25519")
        fakeClient.connectResult = .failure(SSHError.hostKeyMismatch(observed: rejectedKey))
        let manager = makeManager(fakeClient)
        manager.hostKeyMismatchHandler = { _, _ in false }

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error, Never>) in
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { Issue.record("onSuccess should not fire on a mismatch") },
                onError: { error in continuation.resume(returning: error) }
            )
        }

        guard case SSHError.hostKeyMismatch = error else {
            Issue.record("Expected hostKeyMismatch, got \(error)")
            return
        }
    }

    @Test func aProviderThatCannotResolveTrustFailsInsteadOfTrustingOnFirstUse() async {
        let fakeClient = FakeSSHClient()
        fakeClient.connectResult = .success(SSHHostKeyInfo(fingerprint: "SHA256:good", keyType: "ssh-ed25519"))
        let manager = makeManager(fakeClient)
        manager.trustedHostKeyProvider = { _ in nil }

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error, Never>) in
            manager.handleConnection(
                host: "test.local", username: "u", password: "p",
                onSuccess: { Issue.record("onSuccess should not fire when trust can't be resolved") },
                onError: { error in continuation.resume(returning: error) }
            )
        }

        guard case SSHError.connectionFailed = error else {
            Issue.record("Expected connectionFailed, got \(error)")
            return
        }
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
