import Foundation

/// Transport-independent assembler for the interactive `osascript -i` output
/// stream. Extracted from `StreamingShellHandler` so the framing logic can be
/// unit-tested without NIO. Fed raw output chunks; emits completed command
/// outputs matched by their sentinels.
///
/// The interpreter (PTY, echo off) emits, per evaluated statement, a `=> value`
/// result line or a `!! message` error line, each possibly prefixed by one or
/// more `>> ` / `?> ` prompts. A command is complete when the line
/// `=> "<sentinel>"` arrives. AppleScript-level errors are returned *as output*
/// (not thrown) so the caller can keep the channel warm.
struct StreamingResponseParser {
    struct Completion: Equatable {
        let sentinel: String
        let output: String
        let isError: Bool
    }

    private struct Pending {
        let sentinel: String
        var latestResult = ""
        var latestError: String? = nil
    }

    private var queue: [Pending] = []
    private var lineBuffer = ""
    let maxLineBuffer: Int

    init(maxLineBuffer: Int = 100_000) { self.maxLineBuffer = maxLineBuffer }

    var bufferedByteCount: Int { lineBuffer.count }
    var headSentinel: String? { queue.first?.sentinel }

    /// Register a command awaiting its sentinel.
    mutating func addCommand(sentinel: String) {
        queue.append(Pending(sentinel: sentinel))
    }

    /// Remove a pending command (e.g. on timeout). Returns true if present.
    @discardableResult
    mutating func removeCommand(sentinel: String) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.sentinel == sentinel }) else { return false }
        queue.remove(at: idx)
        return true
    }

    /// Discard all state (channel closed / reset).
    mutating func reset() {
        queue.removeAll()
        lineBuffer = ""
    }

    /// Ingest a raw output chunk; return any commands completed by it.
    mutating func ingest(_ chunk: String) -> [Completion] {
        // Strip CR before buffering. Over a PTY, ONLCR turns every "\n" into
        // "\r\n", and in Swift "\r\n" is a SINGLE Character (grapheme cluster),
        // so `firstIndex(of: "\n")` would never find a boundary. Removing "\r"
        // leaves bare "\n" separators.
        lineBuffer += chunk.replacingOccurrences(of: "\r", with: "")
        guard lineBuffer.contains("\n") else { return [] }

        // Split once (linear) rather than repeatedly trimming the front of the
        // buffer, which copied the whole remainder per line — O(n²) on a
        // multi-line burst, on the shared NIO event loop. The final piece is
        // the trailing partial line (empty when the chunk ended in "\n") and
        // becomes the new buffer.
        var lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        lineBuffer = String(lines.removeLast())

        var completions: [Completion] = []
        for line in lines {
            if let completion = handleLine(String(line)) {
                completions.append(completion)
            }
        }
        return completions
    }

    private mutating func handleLine(_ rawLine: String) -> Completion? {
        // No command in flight → stray output (startup noise, late data): ignore.
        guard !queue.isEmpty else { return nil }

        // Strip leading `>> ` / `?> ` prompts (which stack with echo off) before
        // classifying; only `=> ` (result) and `!! ` (error) lines are meaningful.
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        line = Self.stripPrompts(line)
        if line.isEmpty { return nil }

        if line == "=> \"\(queue[0].sentinel)\"" {
            let pending = queue.removeFirst()
            if let err = pending.latestError {
                return Completion(sentinel: pending.sentinel, output: err, isError: true)
            }
            return Completion(sentinel: pending.sentinel, output: pending.latestResult, isError: false)
        }

        if line.hasPrefix("=> ") {
            queue[0].latestResult = Self.unquote(String(line.dropFirst(3)))
        } else if line.hasPrefix("!! ") {
            queue[0].latestError = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Strip leading interactive prompts (`>> `, `?> `) which `osascript -i`
    /// prints before each input. With echo off these prefix the result line and
    /// can accumulate (`>> >> => …`). Only leading prompts are removed, so a
    /// value containing `>>`/`<<` after `=> "` is untouched.
    static func stripPrompts(_ line: String) -> String {
        var s = Substring(line)
        while s.hasPrefix(">>") || s.hasPrefix("?>") {
            s = s.dropFirst(2)
            while s.first == " " { s = s.dropFirst() }
        }
        return String(s)
    }

    /// Strip the surrounding quotes `osascript -s s` adds to string results and
    /// unescape `\"` / `\\`. Numbers and booleans (unquoted) pass through as-is.
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
        let inner = t.dropFirst().dropLast()
        var out = ""
        out.reserveCapacity(inner.count)
        var escaped = false
        for ch in inner {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)   // \" -> ", \\ -> \, anything else literal
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}
