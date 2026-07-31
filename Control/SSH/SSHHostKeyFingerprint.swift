import Foundation
import NIOSSH
import CryptoKit

/// The observed identity of a Mac's SSH host key: enough to pin it
/// (`fingerprint`) and to point an advanced user at the right local file to
/// verify it by hand (`keyType`).
struct SSHHostKeyInfo: Equatable {
    let fingerprint: String   // "SHA256:<base64, unpadded>" — matches `ssh-keygen -lf`
    let keyType: String       // raw NIOSSH algorithm id, e.g. "ssh-ed25519"
}

enum SSHHostKeyFingerprint {
    enum ComputeError: Error {
        case malformedOpenSSHLine
        case invalidBase64
    }

    /// `String(openSSHPublicKey:)` always returns exactly "algorithm-id
    /// base64blob" — a single split on the first space is exact. Decoding the
    /// base64 recovers the raw SSH wire-format key blob (RFC 4253 §6.6),
    /// which is what `ssh-keygen -lf` hashes to produce its fingerprint.
    static func compute(for hostKey: NIOSSHPublicKey) throws -> SSHHostKeyInfo {
        let line = String(openSSHPublicKey: hostKey)
        guard let spaceIndex = line.firstIndex(of: " ") else {
            throw ComputeError.malformedOpenSSHLine
        }
        let keyType = String(line[line.startIndex..<spaceIndex])
        let base64Blob = String(line[line.index(after: spaceIndex)...])
        guard let blob = Data(base64Encoded: base64Blob) else {
            throw ComputeError.invalidBase64
        }
        let digest = Data(SHA256.hash(data: blob))
        let unpadded = digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return SSHHostKeyInfo(fingerprint: "SHA256:\(unpadded)", keyType: keyType)
    }

    /// Maps the negotiated host-key algorithm to the file an advanced user
    /// can inspect *locally on the Mac* to independently verify the
    /// fingerprint. RSA is intentionally absent: swift-nio-ssh never
    /// negotiates it (only ed25519/ecdsa-* are offered).
    static func localVerificationPath(for keyType: String) -> String? {
        switch keyType {
        case "ssh-ed25519":
            return "/etc/ssh/ssh_host_ed25519_key.pub"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return "/etc/ssh/ssh_host_ecdsa_key.pub"
        default:
            return nil
        }
    }
}
