import Testing
import Foundation
@testable import Control

/// Isolates each test from the shared `UserDefaults.standard` key
/// `SavedConnections` reads/writes, since the model has no injectable store.
private func withCleanSavedConnectionsDefaults(_ body: () throws -> Void) rethrows {
    let key = "SavedConnections"
    let previous = UserDefaults.standard.data(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    try body()
}

/// Serialized: these tests all mutate the one shared `UserDefaults.standard`
/// "SavedConnections" key (the model has no injectable store), so running them
/// in parallel would let one test's clear/restore race another's read/write.
@Suite(.serialized)
struct SavedConnectionsHostKeyFingerprintTests {

    @Test func roundTripsFingerprintAndKeyType() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            connections.add(hostname: "test.local", name: "Test Mac", saveCredentials: false)

            #expect(connections.hostKeyFingerprint(for: "test.local") == nil)
            #expect(connections.hostKeyType(for: "test.local") == nil)

            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:abc123", keyType: "ssh-ed25519")

            #expect(connections.hostKeyFingerprint(for: "test.local") == "SHA256:abc123")
            #expect(connections.hostKeyType(for: "test.local") == "ssh-ed25519")
        }
    }

    @Test func noOpsWhenHostnameHasNoSavedRow() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            // No `add(...)` call — this hostname has no row.
            connections.updateHostKeyFingerprint("never-added.local", fingerprint: "SHA256:xyz", keyType: "ssh-ed25519")
            #expect(connections.hostKeyFingerprint(for: "never-added.local") == nil)
        }
    }

    @Test func overwritingAnExistingFingerprintIsHarmless() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            connections.add(hostname: "test.local", saveCredentials: false)
            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:first", keyType: "ssh-ed25519")
            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:second", keyType: "ssh-ed25519")
            #expect(connections.hostKeyFingerprint(for: "test.local") == "SHA256:second")
        }
    }

    /// Pinning accumulates every confirmed key into the trusted set (rather
    /// than replacing), so a Mac that presents a previously-accepted key is
    /// still recognized after a newer one has also been confirmed.
    @Test func trustedSetAccumulatesEveryConfirmedKey() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            connections.add(hostname: "test.local", saveCredentials: false)

            #expect(connections.trustedHostKeyFingerprints(for: "test.local") == [])

            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:first", keyType: "ssh-ed25519")
            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:second", keyType: "ecdsa-sha2-nistp256")

            // Both keys are trusted; primary/display tracks the most recent.
            #expect(connections.trustedHostKeyFingerprints(for: "test.local") == ["SHA256:first", "SHA256:second"])
            #expect(connections.hostKeyFingerprint(for: "test.local") == "SHA256:second")

            // Re-pinning an already-trusted key doesn't duplicate it.
            connections.updateHostKeyFingerprint("test.local", fingerprint: "SHA256:first", keyType: "ssh-ed25519")
            #expect(connections.trustedHostKeyFingerprints(for: "test.local") == ["SHA256:first", "SHA256:second"])
        }
    }

    /// A connection pinned before the trusted-set field existed (only the
    /// legacy single `hostKeyFingerprint`) must still be trusted.
    @Test func legacySingleFingerprintMigratesIntoTrustedSet() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            connections.add(hostname: "legacy.local", saveCredentials: false)
            connections.updateHostKeyFingerprint("legacy.local", fingerprint: "SHA256:legacy", keyType: "ssh-ed25519")
            #expect(connections.trustedHostKeyFingerprints(for: "legacy.local").contains("SHA256:legacy"))
        }
    }

    /// Simulates the exact scenario a pre-existing user hits after updating to
    /// a build with pinning: a connection that has already connected
    /// successfully (under the old, unpinned behavior) still has no
    /// fingerprint. The backfill-logging branch must not change the write's
    /// outcome — same silent pin as any other first-time pin.
    @Test func legacyConnectionWithNoBaselineStillPinsNormally() throws {
        try withCleanSavedConnectionsDefaults {
            let connections = SavedConnections()
            connections.add(hostname: "legacy.local", saveCredentials: false)
            connections.markAsConnected("legacy.local")

            #expect(connections.hasConnectedBefore("legacy.local") == true)
            #expect(connections.hostKeyFingerprint(for: "legacy.local") == nil)

            connections.updateHostKeyFingerprint("legacy.local", fingerprint: "SHA256:backfilled", keyType: "ssh-ed25519")

            #expect(connections.hostKeyFingerprint(for: "legacy.local") == "SHA256:backfilled")
            #expect(connections.hostKeyType(for: "legacy.local") == "ssh-ed25519")
        }
    }
}

struct SavedConnectionMigrationTests {

    /// Simulates real pre-migration data: a `SavedConnection` encoded before
    /// the host-key fields existed. Strips those keys from the encoded JSON
    /// (rather than hand-writing a JSON literal, which risks getting
    /// Foundation's default `Date`/`UUID` encoding format wrong) and confirms
    /// decoding still succeeds with the new fields `nil`.
    @Test func decodesPreMigrationJSONWithoutTheNewFields() throws {
        let modern = SavedConnections.SavedConnection(hostname: "old.local", name: "Old Mac", username: "ryan")
        let encoded = try JSONEncoder().encode(modern)

        var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "hostKeyFingerprint")
        dict.removeValue(forKey: "hostKeyType")
        dict.removeValue(forKey: "hostKeyFingerprints")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(SavedConnections.SavedConnection.self, from: strippedData)
        #expect(decoded.hostname == "old.local")
        #expect(decoded.hostKeyFingerprint == nil)
        #expect(decoded.hostKeyType == nil)
        #expect(decoded.hostKeyFingerprints == nil)
    }
}
