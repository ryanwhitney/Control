import Foundation

/// Tokens used to frame and match AppleScript results streamed over the SSH
/// channel.
///
/// Media titles, device names, and arbitrary app output travel through the same
/// text stream we parse, so every token here is made deliberately distinctive —
/// an uncommon fixed prefix plus a random per-launch `nonce` — so a real title
/// (e.g. a song literally named "NOT_RUNNING") can never be mistaken for a
/// control token. This is collision-avoidance, not security, so a short nonce
/// is plenty: the odds of a genuine title matching are effectively nil.
enum ScriptTokens {
    /// Random per-launch nonce. Crockford-ish base32 with ambiguous characters
    /// (0/O/1/I) removed. 8 chars ≈ 40 bits — far beyond "99.9% unique".
    static let nonce: String = {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }()

    /// Per-command completion sentinel, emitted as the final AppleScript result
    /// and matched *exactly* by `StreamingShellHandler`. `counter` distinguishes
    /// in-flight commands. Uses only `[A-Z0-9_]` so it can never collide with the
    /// interpreter's own `>>`/`?>`/`=>`/`!!` markers or be altered by escaping.
    static func sentinel(_ counter: UInt32) -> String {
        "VC7CTRL_\(nonce)_\(String(format: "%04X", counter & 0xFFFF))_END"
    }

    /// Returned by status scripts when the target app isn't running, matched
    /// exactly by `AppController`.
    static let notRunning = "VC7NOTRUNNING_\(nonce)"

    /// Field separator between the title/subtitle/isPlaying fields of platform
    /// status output, split by `AppPlatform.parseSeparatedState`. Deliberately
    /// distinctive so a media title can't collide with it. Fixed (no nonce):
    /// it appears inside script string literals where a per-launch value adds
    /// nothing — collision here garbles one parse, not control flow.
    static let fieldSeparator = "~|VCF|~"

    /// Heartbeat reply token (matched via `contains`).
    static func heartbeat(_ counter: UInt32) -> String {
        "VC7HB_\(nonce)_\(String(format: "%05u", counter))"
    }

    /// Health-check reply token (matched via `contains`); random per call so a
    /// stale reply can't satisfy a later check.
    static func healthCheck() -> String {
        "VC7HEALTH_\(nonce)_\(String(format: "%08X", UInt32.random(in: 0 ..< .max)))"
    }
}
