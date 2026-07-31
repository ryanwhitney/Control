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

    /// The address-repair migration: the row and its pinned trust follow the
    /// new hostname, and nothing is left behind under the old one.
    @Test func updateHostnameMovesTheRowAndItsTrust() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: "ryan", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "mac-mini.local")

        connections.updateHostname(from: "mac-mini.local", to: "mac-mini-2.local")

        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini-2.local") == ["SHA256:ed"])
        #expect(connections.trustedHostKeys(for: "mac-mini.local").isEmpty)
        #expect(connections.lastUsername(for: "mac-mini-2.local") == "ryan")
        #expect(connections.items.count == 1)
    }

    /// Migrating onto a hostname that already has its own row would merge two
    /// Macs' identities, so it must refuse.
    @Test func updateHostnameRefusesToClobberAnExistingRow() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", saveCredentials: false)
        connections.add(hostname: "mac-mini-2.local", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:ed", keyType: ed25519), for: "mac-mini.local")
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:other", keyType: ed25519), for: "mac-mini-2.local")

        connections.updateHostname(from: "mac-mini.local", to: "mac-mini-2.local")

        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini.local") == ["SHA256:ed"])
        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini-2.local") == ["SHA256:other"])
    }

    /// No row for the source hostname → nothing happens.
    @Test func updateHostnameNoOpsWithoutASourceRow() {
        let connections = makeTestConnections()
        connections.updateHostname(from: "ghost.local", to: "somewhere.local")
        #expect(connections.items.isEmpty)
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

/// Hostnames are case-insensitive (mDNS/DNS), so two spellings must never
/// become two rows: host-key trust would land on one and the setup state on
/// the other, and deleting the wrong one would silently drop the pin.
struct SavedConnectionsCaseInsensitivityTests {

    @Test func addUpdatesTheExistingRowRatherThanDuplicatingIt() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: "ryan", saveCredentials: false)
        connections.add(hostname: "Mac-Mini.local", name: "Mac mini", username: "ryan2", saveCredentials: false)

        #expect(connections.items.count == 1)
        #expect(connections.lastUsername(for: "mac-mini.local") == "ryan2")
    }

    /// A pin written under one spelling and setup state read under another
    /// have to land on the same row.
    @Test func trustAndSetupStateShareOneRowAcrossSpellings() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", saveCredentials: false)

        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: "MAC-MINI.local")
        connections.updateEnabledPlatforms("Mac-Mini.local", platforms: ["music"])
        connections.markAsConnected("mac-MINI.local")

        #expect(connections.items.count == 1)
        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini.local") == ["SHA256:abc"])
        #expect(connections.enabledPlatforms("mac-mini.local") == ["music"])
        #expect(connections.hasConnectedBefore("mac-mini.local"))
    }

    @Test func removeMatchesRegardlessOfSpelling() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", saveCredentials: false)

        connections.remove(hostname: "MAC-MINI.local")

        #expect(connections.items.isEmpty)
    }

    /// A hand-typed FQDN carries the trailing root dot Bonjour discovery
    /// strips, so both spellings have to resolve to the one row — otherwise
    /// the second silently trusts-on-first-use under an empty pin set.
    @Test func trailingRootDotResolvesToTheSameRow() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: "mac-mini.local")

        connections.add(hostname: "mac-mini.local.", name: "Mac mini", saveCredentials: false)

        #expect(connections.items.count == 1)
        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini.local.") == ["SHA256:abc"])
        // Uppercase too: the dot strip must not be case-sensitive.
        #expect(connections.trustedHostKeyFingerprints(for: "MAC-MINI.LOCAL.") == ["SHA256:abc"])
    }

    /// The root dot is meaningless for every DNS name, so a remote hostname
    /// typed with one has to land on the pinned row rather than forking a
    /// second one that would trust whatever answered.
    @Test func trailingRootDotResolvesToTheSameRowForARemoteHostname() {
        let connections = makeTestConnections()
        connections.add(hostname: "home.example.com", name: "Mac mini", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: "home.example.com")

        connections.add(hostname: "home.example.com.", name: "Mac mini", saveCredentials: false)

        #expect(connections.items.count == 1)
        #expect(connections.trustedHostKeyFingerprints(for: "home.example.com.") == ["SHA256:abc"])
    }

    @Test func lookupsResolveUnderEitherSpelling() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: "ryan", saveCredentials: false)
        connections.updateLastViewedPlatform("MAC-MINI.local", platform: "vlc")

        #expect(connections.connection(for: "Mac-Mini.local")?.name == "Mac mini")
        #expect(connections.lastUsername(for: "MAC-MINI.local") == "ryan")
        #expect(connections.lastViewedPlatform("mac-mini.local") == "vlc")
    }

    @Test func updateNameRenamesInPlaceWithoutTouchingAddressOrTrust() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", saveCredentials: false)
        connections.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: "mac-mini.local")

        connections.updateName("Mac mini (2)", for: "MAC-MINI.local")

        #expect(connections.items.count == 1)
        #expect(connections.connection(for: "mac-mini.local")?.name == "Mac mini (2)")
        #expect(connections.connection(for: "mac-mini.local")?.hostname == "mac-mini.local")
        #expect(connections.trustedHostKeyFingerprints(for: "mac-mini.local") == ["SHA256:abc"])
    }

    /// The repair path connects to the replacement address only when the row
    /// actually moved, so the move has to report whether it happened.
    @Test func updateHostnameReportsWhetherItMoved() {
        let connections = makeTestConnections()
        connections.add(hostname: "old.local", name: "Mac mini", saveCredentials: false)

        #expect(connections.updateHostname(from: "old.local", to: "new.local"))
        #expect(!connections.updateHostname(from: "missing.local", to: "other.local"))

        connections.add(hostname: "taken.local", name: "Other", saveCredentials: false)
        #expect(!connections.updateHostname(from: "new.local", to: "TAKEN.local"))
    }
}

/// `add` is reached both by a connect that has just authenticated and by the
/// optional-credentials add, which has no login to write. What the second one
/// omits must survive rather than being overwritten with nothing.
struct SavedConnectionsPartialUpdateTests {

    @Test func addWithoutAUsernameKeepsTheStoredOne() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: "ryan", saveCredentials: true)

        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: nil, saveCredentials: nil)

        #expect(connections.lastUsername(for: "mac-mini.local") == "ryan")
    }

    @Test func addWithoutACredentialsDecisionKeepsThePreference() {
        let connections = makeTestConnections()
        connections.add(hostname: "mac-mini.local", name: "Mac mini", username: "ryan", saveCredentials: true)

        connections.add(hostname: "mac-mini.local", name: "Mac mini", saveCredentials: nil)

        #expect(connections.connection(for: "mac-mini.local")?.saveCredentialsPreference == true)
    }

    /// Re-adding an already-saved Mac from the "+" sheet must not take its
    /// saved login with it.
    @Test func addWithoutACredentialsDecisionKeepsTheStoredPassword() {
        let connections = makeTestConnections()
        let host = "keep-password-\(UUID().uuidString).local"
        defer { connections.remove(hostname: host) }
        connections.add(hostname: host, name: "Mac mini", username: "ryan", password: "hunter2", saveCredentials: true)
        #expect(connections.password(for: host) == "hunter2")

        connections.add(hostname: host, name: "Mac mini", saveCredentials: nil)

        #expect(connections.password(for: host) == "hunter2")
    }

    @Test func addWithCredentialsOffStillClearsTheStoredPassword() {
        let connections = makeTestConnections()
        let host = "clear-password-\(UUID().uuidString).local"
        defer { connections.remove(hostname: host) }
        connections.add(hostname: host, name: "Mac mini", username: "ryan", password: "hunter2", saveCredentials: true)

        connections.add(hostname: host, name: "Mac mini", username: "ryan", saveCredentials: false)

        #expect(connections.password(for: host) == nil)
    }
}

/// Rows saved before the root dot was stripped for every hostname have to be
/// brought forward on load, Keychain entry included — they are keyed by the
/// stored spelling, so a rewritten row would otherwise lose its password.
struct SavedConnectionsMigrationTests {

    @Test func loadNormalizesStoredHostnamesAndCarriesThePasswordOver() {
        let suiteName = "SavedConnectionsMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let host = "migrate-\(UUID().uuidString).example.com"

        let seeded = SavedConnections(defaults: defaults)
        seeded.add(hostname: host + ".", name: "Mac mini", username: "ryan", password: "hunter2", saveCredentials: true)
        seeded.pinHostKey(SSHHostKeyInfo(fingerprint: "SHA256:abc", keyType: ed25519), for: host + ".")
        #expect(seeded.connection(for: host)?.hostname == host + ".")

        let reloaded = SavedConnections(defaults: defaults)
        defer { reloaded.remove(hostname: host) }

        #expect(reloaded.items.count == 1)
        #expect(reloaded.connection(for: host)?.hostname == host)
        #expect(reloaded.password(for: host) == "hunter2")
        #expect(reloaded.trustedHostKeyFingerprints(for: host) == ["SHA256:abc"])
    }

    /// Merging two rows would mean picking one Mac's password for the other,
    /// so a row whose normalized spelling is already taken is left as it is.
    @Test func loadLeavesARowWhoseNormalizedSpellingIsTaken() {
        let suiteName = "SavedConnectionsMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let seeded = [
            SavedConnections.SavedConnection(hostname: "shared.example.com", name: "First"),
            SavedConnections.SavedConnection(hostname: "shared.example.com.", name: "Second")
        ]
        defaults.set(try! JSONEncoder().encode(seeded), forKey: "SavedConnections")

        let reloaded = SavedConnections(defaults: defaults)

        #expect(reloaded.items.count == 2)
        #expect(reloaded.items.map(\.hostname) == ["shared.example.com", "shared.example.com."])
    }
}
