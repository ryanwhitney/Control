import Testing
import Foundation
@testable import Control

/// A private, throwaway `UserDefaults` suite so each test is isolated both from
/// the app's real `UserDefaults.standard` and from other tests — no shared
/// state to clear, so nothing to race or to leave behind on a crash.
private func makeTestConnections() -> SavedConnections {
    let suiteName = "SavedConnectionsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return SavedConnections(defaults: defaults)
}

private let ed25519 = "ssh-ed25519"
private let ecdsa = "ecdsa-sha2-nistp256"

struct SavedConnectionsHostKeyTests {

    @Test func pinsAndReadsBackAKey() {
        let connections = makeTestConnections()
        connections.add(hostname: "test.local", name: "Test Mac", saveCredentials: false)

        #expect(connections.trustedHostKeys(for: "test.local").isEmpty)

        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: "test.local")

        #expect(connections.trustedHostKeyFingerprints(for: "test.local") == ["SHA256:abc"])
        #expect(connections.trustedHostKeys(for: "test.local").first?.keyType == ed25519)
    }

    @Test func noOpsWhenHostnameHasNoSavedRow() {
        let connections = makeTestConnections()
        // No `add(...)` — this hostname has no row.
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:xyz", keyType: ed25519), for: "never-added.local")
        #expect(connections.trustedHostKeys(for: "never-added.local").isEmpty)
    }

    /// A confirmed key change replaces the old key of the *same type*, so the
    /// superseded key stops being trusted — the security-relevant behavior.
    @Test func newKeyOfSameTypeReplacesTheOldOne() {
        let connections = makeTestConnections()
        connections.add(hostname: "test.local", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:first", keyType: ed25519), for: "test.local")
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:second", keyType: ed25519), for: "test.local")

        #expect(connections.trustedHostKeyFingerprints(for: "test.local") == ["SHA256:second"])
    }

    /// A key of a *different* type coexists — a Mac can legitimately offer more
    /// than one algorithm.
    @Test func keysOfDifferentTypesCoexist() {
        let connections = makeTestConnections()
        connections.add(hostname: "test.local", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "test.local")
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ec", keyType: ecdsa), for: "test.local")

        #expect(connections.trustedHostKeyFingerprints(for: "test.local") == ["SHA256:ed", "SHA256:ec"])
    }

    /// Re-pinning the identical key doesn't grow the set.
    @Test func rePinningTheSameKeyIsIdempotent() {
        let connections = makeTestConnections()
        connections.add(hostname: "test.local", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "test.local")
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "test.local")

        #expect(connections.trustedHostKeys(for: "test.local").count == 1)
    }

    /// Trust is matched case-insensitively, so a Mac pinned under one spelling
    /// isn't silently re-trusted (TOFU) under a differently-cased spelling, and
    /// a later pin updates the same row rather than forking a second trust set.
    @Test func trustLookupIsCaseInsensitive() {
        let connections = makeTestConnections()
        connections.add(hostname: "ryans-macbook.local", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "ryans-macbook.local")

        #expect(connections.trustedHostKeyFingerprints(for: "Ryans-MacBook.local") == ["SHA256:ed"])

        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ec", keyType: ecdsa), for: "RYANS-MACBOOK.LOCAL")
        #expect(connections.trustedHostKeyFingerprints(for: "ryans-macbook.local") == ["SHA256:ed", "SHA256:ec"])
    }
}

struct SavedConnectionMigrationTests {

    /// Simulates real pre-pinning data: a `SavedConnection` encoded before the
    /// host-key field existed. Strips the field from the encoded JSON (rather
    /// than hand-writing a JSON literal, which risks getting Foundation's
    /// default `Date`/`UUID` encoding wrong) and confirms decoding still
    /// succeeds with the new field `nil`.
    @Test func decodesPreMigrationJSONWithoutTheNewField() throws {
        let modern = SavedConnections.SavedConnection(hostname: "old.local", name: "Old Mac", username: "ryan")
        let encoded = try JSONEncoder().encode(modern)

        var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "trustedHostKeys")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(SavedConnections.SavedConnection.self, from: strippedData)
        #expect(decoded.hostname == "old.local")
        #expect(decoded.trustedHostKeys == nil)
    }
}
