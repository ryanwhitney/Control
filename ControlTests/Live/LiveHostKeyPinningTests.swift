import Testing
import Foundation
@testable import Control

/// Live host-key pinning against a real sshd. The pure-Swift tests drive
/// `HostKeyPinningDelegate` with a synthetic key; only these prove the pin is
/// actually enforced end to end — that a real handshake against a real server
/// is accepted when the fingerprint matches and refused when it doesn't, and
/// that the fingerprint the app computes is the one OpenSSH reports.
///
/// Inert unless `VC_LIVE=1` with credentials set (see `LiveEnvironment`).
/// Nothing is hardcoded about the target Mac: the expected fingerprint is
/// discovered from a trust-on-first-use connect and reused by the rest.
@Suite(.serialized, .enabled(if: LiveEnvironment.isEnabled), .tags(.live), .timeLimit(.minutes(2)))
struct LiveHostKeyPinningTests {

    private func credentials() throws -> (host: String, user: String, pass: String) {
        guard let user = LiveEnvironment.value("VC_LIVE_USER"), !user.isEmpty,
              let pass = LiveEnvironment.value("VC_LIVE_PASS"), !pass.isEmpty else {
            throw LiveEnvironment.LiveError.missingCredentials("set VC_LIVE_USER / VC_LIVE_PASS")
        }
        return (LiveEnvironment.value("VC_LIVE_HOST") ?? "127.0.0.1", user, pass)
    }

    /// Opens one real connection and returns the key the server presented.
    private func connect(trusting trusted: Set<String>) async throws -> SSHHostKeyInfo {
        let (host, user, pass) = try credentials()
        let client = SSHClient()
        defer { client.disconnect() }
        return try await withCheckedThrowingContinuation { cont in
            client.connect(host: host, username: user, password: pass, trustedHostKeyFingerprints: trusted) {
                cont.resume(with: $0)
            }
        }
    }

    /// An empty trusted set is trust-on-first-use, and the key it reports back
    /// is what the pin is built from — so it has to be the server's real key.
    @Test func trustOnFirstUseReportsTheServersKey() async throws {
        let observed = try await connect(trusting: [])
        #expect(observed.fingerprint.hasPrefix("SHA256:"))
        #expect(!observed.keyType.isEmpty)
    }

    /// The pin is enforced, not merely recorded: presenting the key the server
    /// actually has succeeds, and a well-formed but wrong key is refused with
    /// the mismatch the recovery flow keys off — carrying the real key so the
    /// review screen can show what was actually offered.
    @Test func matchingPinConnectsAndWrongPinIsRejected() async throws {
        let observed = try await connect(trusting: [])

        let reconnected = try await connect(trusting: [observed.fingerprint])
        #expect(reconnected.fingerprint == observed.fingerprint)

        await #expect(throws: SSHError.self) {
            _ = try await connect(trusting: ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
        }

        do {
            _ = try await connect(trusting: ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
            Issue.record("A wrong pin must not connect")
        } catch let error as SSHError {
            guard case .hostKeyMismatch(let rejected) = error else {
                Issue.record("Expected hostKeyMismatch, got \(error)")
                return
            }
            #expect(rejected.fingerprint == observed.fingerprint)
        }
    }

    /// Trusting a *different* host's key must not let this host through: the
    /// check is per-key, not "is the set non-empty".
    @Test func anUnrelatedTrustedKeyDoesNotSatisfyThePin() async throws {
        let observed = try await connect(trusting: [])
        let unrelated = "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c"
        // Guard the fixture: if this ever equals the real key the test proves nothing.
        try #require(unrelated != observed.fingerprint)

        do {
            _ = try await connect(trusting: [unrelated])
            Issue.record("An unrelated pinned key must not authorize this host")
        } catch let error as SSHError {
            guard case .hostKeyMismatch = error else {
                Issue.record("Expected hostKeyMismatch, got \(error)")
                return
            }
        }
    }

    /// A rejection is reported by the delegate and the teardown is left to
    /// NIOSSH, so this checks the handshake actually unwinds: each attempt has
    /// to come back classified as a mismatch (not the generic error NIOSSH's
    /// own teardown would surface if it won the race) and well inside the 5 s
    /// watchdog, which is what a connection left hanging open would blow.
    @Test func repeatedRejectionsUnwindPromptly() async throws {
        let wrong: Set<String> = ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
        let started = Date()

        for attempt in 1...3 {
            do {
                _ = try await connect(trusting: wrong)
                Issue.record("A wrong pin must not connect (attempt \(attempt))")
            } catch let error as SSHError {
                guard case .hostKeyMismatch = error else {
                    Issue.record("Attempt \(attempt): expected hostKeyMismatch, got \(error)")
                    return
                }
            }
        }

        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// The batch probe shares one event-loop group and shuts it down when the
    /// last host answers, so a host that never responds must hold the group up
    /// until its connect settles rather than letting the shutdown race it.
    @Test func probingUnreachableHostsAlongsideAReachableOneStaysClean() async throws {
        let (host, _, _) = try credentials()
        let observed = try await connect(trusting: [])
        // RFC 5737 documentation addresses: routable nowhere, so these hang
        // until the connect timeout — the case that raced the group shutdown.
        let hosts = [host, "192.0.2.1", "192.0.2.2", "192.0.2.3"]

        let started = Date()
        let found = await SSHTransportConnector.probeHostKeys(hosts: hosts, timeout: 3.0)
        let elapsed = Date().timeIntervalSince(started)

        #expect(found[host]?.fingerprint == observed.fingerprint)
        #expect(found.count == 1)
        // Concurrent, so the batch costs one timeout rather than three.
        #expect(elapsed < 6)
    }

    /// The address-repair probe reads the same key the authenticated connect
    /// sees, without credentials — the property the repair offer's "this really
    /// is your Mac" claim rests on.
    @Test func credentialFreeProbeSeesTheSameKey() async throws {
        let (host, _, _) = try credentials()
        let observed = try await connect(trusting: [])

        let probed = await SSHTransportConnector.probeHostKey(host: host, timeout: 5.0)
        let probedKey = try #require(probed, "probe returned no key for a reachable host")
        #expect(probedKey.fingerprint == observed.fingerprint)
        #expect(probedKey.keyType == observed.keyType)
    }

    /// The fingerprint the app shows is the one the Mac prints for itself.
    /// This is the comparison the review screen asks the user to make by hand,
    /// so a mismatch here means the verification flow tells them to reject a
    /// legitimate Mac.
    @Test func computedFingerprintMatchesSSHKeygenOnTheMac() async throws {
        let observed = try await connect(trusting: [])
        let path = try #require(
            SSHHostKeyFingerprint.localVerificationPath(for: observed.keyType),
            "no local verification path for \(observed.keyType)"
        )

        let env = try await LiveEnvironment()
        defer { env.disconnect() }
        let printed = try await env.run("do shell script \"ssh-keygen -lf \(path)\"")

        #expect(printed.contains(observed.fingerprint))
    }

    /// The compatibility transport pins through the same path as streaming.
    @Test func compatibilityTransportEnforcesThePinToo() async throws {
        let (host, user, pass) = try credentials()

        let client = LegacySSHClient()
        let observed: SSHHostKeyInfo = try await withCheckedThrowingContinuation { cont in
            client.connect(host: host, username: user, password: pass, trustedHostKeyFingerprints: []) {
                cont.resume(with: $0)
            }
        }
        client.disconnect()
        #expect(observed.fingerprint.hasPrefix("SHA256:"))

        let rejecting = LegacySSHClient()
        defer { rejecting.disconnect() }
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SSHHostKeyInfo, Error>) in
                rejecting.connect(
                    host: host,
                    username: user,
                    password: pass,
                    trustedHostKeyFingerprints: ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
                ) { cont.resume(with: $0) }
            }
            Issue.record("A wrong pin must not connect over the compatibility transport")
        } catch let error as SSHError {
            guard case .hostKeyMismatch = error else {
                Issue.record("Expected hostKeyMismatch, got \(error)")
                return
            }
        }
    }
}
