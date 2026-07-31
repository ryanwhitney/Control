import Testing
import Foundation
@testable import Control

/// The recovery flows driven end to end against a real Mac. A wrong pin is
/// planted in the store, so the mismatch comes from a real handshake with a
/// real server rather than a stubbed error — which is the only way to check
/// that the key surfaced to the review screen is the one actually presented,
/// and that trusting it really does let the next connect through.
///
/// Inert unless `VC_LIVE=1` with credentials set. Each test uses its own
/// hostname spelling and removes its row afterwards, so the simulator's store
/// is left as it was found.
@MainActor
@Suite(.serialized, .enabled(if: LiveEnvironment.isEnabled), .tags(.live), .timeLimit(.minutes(3)))
struct LiveRecoveryFlowTests {

    private static let wrongFingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    private func credentials() throws -> (host: String, user: String, pass: String) {
        guard let user = LiveEnvironment.value("VC_LIVE_USER"), !user.isEmpty,
              let pass = LiveEnvironment.value("VC_LIVE_PASS"), !pass.isEmpty else {
            throw LiveEnvironment.LiveError.missingCredentials("set VC_LIVE_USER / VC_LIVE_PASS")
        }
        return (LiveEnvironment.value("VC_LIVE_HOST") ?? "127.0.0.1", user, pass)
    }

    /// The key the live Mac actually presents, read without credentials.
    private func realKey(host: String) async throws -> SSHHostKeyInfo {
        try #require(await SSHTransportConnector.probeHostKey(host: host, timeout: 5.0),
                     "probe returned no key — is Remote Login on?")
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 30,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("timed out waiting for \(label)")
    }

    /// Builds a view model pointed at the live Mac with `pinned` already
    /// trusted for it, and tears the row down afterwards.
    private func makeViewModel(host: String, pinned: [String]) throws -> ConnectionsViewModel {
        let (_, user, pass) = try credentials()
        let vm = ConnectionsViewModel()
        vm.savedConnections.add(hostname: host, name: "Live Test Mac", username: user, saveCredentials: false)
        for fingerprint in pinned {
            vm.savedConnections.pinHostKey(
                SSHHostKeyInfo(fingerprint: fingerprint, keyType: "ssh-ed25519"),
                for: host
            )
        }
        vm.username = user
        vm.password = pass
        return vm
    }

    private func connection(host: String) -> Connection {
        Connection(id: host, name: "Live Test Mac", host: host, type: .manual, lastUsername: nil)
    }

    /// A real mismatch drives the alert, and the review screen is handed the
    /// key the server actually presented — not the one that was pinned.
    @Test func wrongPinProducesMismatchCarryingTheRealKey() async throws {
        let (host, _, _) = try credentials()
        let real = try await realKey(host: host)

        let vm = try makeViewModel(host: host, pinned: [Self.wrongFingerprint])
        defer {
            vm.savedConnections.remove(hostname: host)
            SSHConnectionManager.shared.disconnect()
        }

        vm.connectWithCredentials(computer: connection(host: host))
        try await waitUntil("mismatch alert") { vm.showingError }

        guard case .hostKeyMismatch(let rejected) = vm.pendingRecovery else {
            Issue.record("expected .hostKeyMismatch, got \(vm.pendingRecovery)")
            return
        }
        #expect(rejected.fingerprint == real.fingerprint)

        let context = try #require(vm.hostKeyReviewContext)
        #expect(context.newKey.fingerprint == real.fingerprint)
        #expect(context.host == host)
        // The screen shows what was trusted before, so the user can compare.
        #expect(context.previousKeys.contains { $0.fingerprint == Self.wrongFingerprint })
    }

    /// Trusting the change reconnects for real and persists the key that was
    /// actually verified, replacing the pin that caused the mismatch.
    @Test func trustingTheChangeReconnectsAndRepinsTheRealKey() async throws {
        let (host, _, _) = try credentials()
        let real = try await realKey(host: host)

        let vm = try makeViewModel(host: host, pinned: [Self.wrongFingerprint])
        defer {
            vm.savedConnections.remove(hostname: host)
            SSHConnectionManager.shared.disconnect()
        }

        vm.connectWithCredentials(computer: connection(host: host))
        try await waitUntil("mismatch alert") { vm.showingError }

        vm.confirmHostKeyChangeAndReconnect()
        try await waitUntil("reconnect to finish") {
            vm.connectingComputer == nil && vm.pendingRecovery == .none
        }

        let trusted = vm.savedConnections.trustedHostKeyFingerprints(for: host)
        #expect(trusted.contains(real.fingerprint))
        // Same key type, so the bad pin is replaced rather than accumulated.
        #expect(!trusted.contains(Self.wrongFingerprint))
    }

    /// Declining trusts nothing: the bad pin stays exactly as it was, and no
    /// part of the real key is recorded.
    @Test func decliningTrustsNothing() async throws {
        let (host, _, _) = try credentials()
        let real = try await realKey(host: host)

        let vm = try makeViewModel(host: host, pinned: [Self.wrongFingerprint])
        defer {
            vm.savedConnections.remove(hostname: host)
            SSHConnectionManager.shared.disconnect()
        }

        vm.connectWithCredentials(computer: connection(host: host))
        try await waitUntil("mismatch alert") { vm.showingError }

        vm.cancelHostKeyMismatch()

        let trusted = vm.savedConnections.trustedHostKeyFingerprints(for: host)
        #expect(!trusted.contains(real.fingerprint))
        #expect(trusted == [Self.wrongFingerprint])
        #expect(vm.pendingRecovery == .none)
        #expect(!vm.showingHostKeyReview)
        // The review screen reads this while it animates away, so it outlives
        // the recovery it belongs to; `pendingRecovery` is what gates reaching it.
        #expect(vm.hostKeyReviewContext != nil)
    }

    /// Optional credentials: a reachable Mac is saved and the login is asked
    /// for, and nothing is pinned on the strength of an unauthenticated probe.
    @Test func addWithoutCredentialsSavesTheMacAndAsksForLogin() async throws {
        let (host, _, _) = try credentials()
        let vm = ConnectionsViewModel()
        defer {
            vm.savedConnections.remove(hostname: host)
            SSHConnectionManager.shared.disconnect()
        }
        vm.savedConnections.remove(hostname: host)
        vm.username = ""
        vm.password = ""

        vm.addConnection(computer: connection(host: host))
        try await waitUntil("auth sheet") { vm.isAuthenticating }

        #expect(vm.savedConnections.connection(for: host) != nil)
        #expect(vm.savedConnections.trustedHostKeyFingerprints(for: host).isEmpty)
    }

    /// An address that answers nothing errors and leaves no row behind, so a
    /// typo can't litter the list.
    @Test func addWithoutCredentialsSavesNothingWhenNothingAnswers() async throws {
        let dead = "203.0.113.1"   // TEST-NET-3, reserved and unroutable
        let vm = ConnectionsViewModel()
        defer {
            vm.savedConnections.remove(hostname: dead)
            SSHConnectionManager.shared.disconnect()
        }
        vm.username = ""
        vm.password = ""

        vm.addConnection(computer: connection(host: dead))
        try await waitUntil("failure alert", timeout: 40) { vm.showingError }

        #expect(vm.savedConnections.connection(for: dead) == nil)
        #expect(!vm.isAuthenticating)
    }

    /// Accepting a repair moves the saved row — pins, name and all — to the
    /// verified address, then reconnects there.
    @Test func acceptingARepairMovesTheRowAndReconnects() async throws {
        let (host, user, pass) = try credentials()
        let real = try await realKey(host: host)
        let stale = "live-test-stale.local"

        let vm = ConnectionsViewModel()
        defer {
            vm.savedConnections.remove(hostname: stale)
            vm.savedConnections.remove(hostname: host)
            SSHConnectionManager.shared.disconnect()
        }
        vm.savedConnections.remove(hostname: host)
        vm.savedConnections.add(hostname: stale, name: "Old Name", username: user, saveCredentials: false)
        vm.savedConnections.pinHostKey(real, for: stale)
        vm.username = user
        vm.password = pass

        let repair = ConnectionsViewModel.AddressRepair(
            computer: Connection(id: stale, name: "Old Name", host: stale, type: .manual, lastUsername: user),
            replacement: Connection(id: host, name: "New Name", host: host, type: .manual, lastUsername: user),
            rejectedKey: SSHHostKeyInfo(fingerprint: Self.wrongFingerprint, keyType: "ssh-ed25519"),
            verifiedFingerprint: real.fingerprint
        )
        vm.acceptAddressRepair(repair)
        try await waitUntil("repair reconnect") { vm.connectingComputer == nil }

        #expect(vm.savedConnections.connection(for: stale) == nil)
        let moved = try #require(vm.savedConnections.connection(for: host))
        #expect(moved.name == "New Name")
        #expect(vm.savedConnections.trustedHostKeyFingerprints(for: host).contains(real.fingerprint))
    }
}
