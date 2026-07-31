import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import Control

/// Known-answer vector: a real `ssh-keygen -t ed25519`-generated keypair, with
/// its fingerprint independently cross-checked via `ssh-keygen -lf` and via a
/// manual `shasum -a 256` + `base64` pipeline — not a value invented for this
/// test. If this ever needs regenerating: `ssh-keygen -t ed25519 -f k -N "" -C ""`,
/// then `ssh-keygen -lf k.pub`.
private let testEd25519PublicKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPNZLTAeKyrk3SRsRnQJh6NTWd7UG0SrL/c6p2XjTXsn"
private let testEd25519Fingerprint = "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c"

struct SSHHostKeyFingerprintComputeTests {

    @Test func matchesRealSSHKeygenOutput() throws {
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let info = try SSHHostKeyFingerprint.compute(for: publicKey)
        #expect(info.fingerprint == testEd25519Fingerprint)
        #expect(info.keyType == "ssh-ed25519")
    }

    @Test func sameKeyAlwaysProducesSameFingerprint() throws {
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let first = try SSHHostKeyFingerprint.compute(for: publicKey)
        let second = try SSHHostKeyFingerprint.compute(for: publicKey)
        #expect(first == second)
    }
}

struct SSHHostKeyFingerprintLocalVerificationPathTests {

    @Test func ed25519MapsToItsHostKeyFile() {
        #expect(SSHHostKeyFingerprint.localVerificationPath(for: "ssh-ed25519") == "/etc/ssh/ssh_host_ed25519_key.pub")
    }

    @Test func allECDSAVariantsMapToTheSharedECDSAHostKeyFile() {
        for keyType in ["ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"] {
            #expect(SSHHostKeyFingerprint.localVerificationPath(for: keyType) == "/etc/ssh/ssh_host_ecdsa_key.pub")
        }
    }

    @Test func unknownKeyTypeReturnsNil() {
        #expect(SSHHostKeyFingerprint.localVerificationPath(for: "ssh-rsa") == nil)
        #expect(SSHHostKeyFingerprint.localVerificationPath(for: "garbage") == nil)
    }
}

/// Guards the pinning decision logic in isolation: no live Mac or TCP
/// connection needed, since `validateHostKey` is a pure function of the
/// presented key plus the delegate's expected-fingerprint state.
struct HostKeyPinningDelegateTests {

    @Test func trustOnFirstUseAcceptsAnyKeyWhenTrustedSetIsEmpty() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = HostKeyPinningDelegate(trustedFingerprints: [])
        var mismatchFired = false
        delegate.onReject = { _ in mismatchFired = true }

        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        #expect(throws: Never.self) { try promise.futureResult.wait() }
        #expect(mismatchFired == false)
        #expect(delegate.observedInfo?.fingerprint == testEd25519Fingerprint)
    }

    @Test func keyInTrustedSetAcceptsSilently() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = HostKeyPinningDelegate(trustedFingerprints: [testEd25519Fingerprint])
        var mismatchFired = false
        delegate.onReject = { _ in mismatchFired = true }

        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        #expect(throws: Never.self) { try promise.futureResult.wait() }
        #expect(mismatchFired == false)
    }

    /// A Mac that legitimately presents more than one accepted key (e.g. after
    /// an OS update changes the negotiated key type) must not false-alarm as
    /// long as the presented key is one the user already trusts.
    @Test func keyIsAcceptedWhenTrustedSetHoldsMultipleKeys() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = HostKeyPinningDelegate(trustedFingerprints: ["SHA256:some-other-key", testEd25519Fingerprint])
        var mismatchFired = false
        delegate.onReject = { _ in mismatchFired = true }

        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        #expect(throws: Never.self) { try promise.futureResult.wait() }
        #expect(mismatchFired == false)
    }

    @Test func keyNotInTrustedSetRejectsAndFiresOnRejectOnce() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = HostKeyPinningDelegate(trustedFingerprints: ["SHA256:not-the-real-one"])
        var rejections: [SSHError] = []
        delegate.onReject = { rejections.append($0) }

        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        #expect(throws: (any Error).self) { try promise.futureResult.wait() }
        #expect(rejections.count == 1)
        // The reject carries the presented key so the caller can offer to trust
        // exactly it — and it's a mismatch, not a generic failure.
        guard case .hostKeyMismatch(let observed) = rejections.first else {
            Issue.record("Expected hostKeyMismatch, got \(String(describing: rejections.first))")
            return
        }
        #expect(observed.fingerprint == testEd25519Fingerprint)
    }

    /// The retry flow depends on this: even a *rejected* key must still be
    /// captured in `observedInfo`, so the caller can add exactly that key to
    /// the trusted set if the user consciously chooses to reconnect.
    @Test func mismatchStillPopulatesObservedInfo() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = HostKeyPinningDelegate(trustedFingerprints: ["SHA256:not-the-real-one"])

        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: testEd25519PublicKeyLine)
        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)
        _ = try? promise.futureResult.wait()

        #expect(delegate.observedInfo?.fingerprint == testEd25519Fingerprint)
        #expect(delegate.observedInfo?.keyType == "ssh-ed25519")
    }
}
