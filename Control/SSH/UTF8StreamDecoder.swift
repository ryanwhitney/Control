import Foundation

/// Incrementally decodes a byte stream as UTF-8 across chunk boundaries.
///
/// SSH/TCP can split a multi-byte character (emoji, CJK, accented Latin) between
/// two channel reads. Decoding each read independently — e.g. via
/// `ByteBuffer.getString` — corrupts the split character: the incomplete tail of
/// the first read decodes to U+FFFD and the continuation bytes at the head of the
/// next read decode to further U+FFFD. This decoder holds back an incomplete
/// trailing sequence and prepends it to the following chunk, so non-ASCII app
/// titles stream through intact.
///
/// Pure and transport-independent, so it is unit-tested without NIO (see
/// `UTF8StreamDecoderTests`). `StreamingShellHandler` owns one per channel.
struct UTF8StreamDecoder {
    /// Trailing bytes from the previous chunk that form an *incomplete* UTF-8
    /// sequence, awaiting their continuation bytes in the next chunk.
    private var remainder: [UInt8] = []

    /// Feed the next raw chunk; returns the decoded text for every code point
    /// completed so far. Any incomplete trailing sequence is buffered for next
    /// time rather than emitted (and corrupted) now.
    mutating func decode(_ bytes: [UInt8]) -> String {
        // No new bytes can't complete a held sequence — keep waiting.
        guard !bytes.isEmpty else { return "" }

        var buf = remainder
        buf.append(contentsOf: bytes)
        remainder = []

        let split = Self.completeLength(of: buf)
        if split == buf.count {
            return String(decoding: buf, as: UTF8.self)
        }
        // Hold the incomplete trailing sequence back for the next chunk.
        remainder = Array(buf[split...])
        return String(decoding: buf[..<split], as: UTF8.self)
    }

    /// Drop any buffered partial sequence (channel closed / reset).
    mutating func reset() { remainder = [] }

    /// Length of the longest prefix of `buf` that ends on a UTF-8 code-point
    /// boundary — i.e. everything except a *completable* incomplete trailing
    /// sequence. A malformed tail (stray continuation bytes, invalid lead) is
    /// treated as complete and decoded lossily, so a bad byte can never wedge the
    /// stream forever.
    static func completeLength(of buf: [UInt8]) -> Int {
        let count = buf.count
        guard count > 0 else { return 0 }

        // A UTF-8 sequence is at most 4 bytes, so any incomplete tail lies within
        // the last 4 bytes. Walk back over continuation bytes (10xxxxxx) to the
        // lead byte that starts the final sequence.
        let lowerBound = max(0, count - 4)
        var i = count - 1
        while i >= lowerBound && (buf[i] & 0xC0) == 0x80 { i -= 1 }
        if i < lowerBound {
            // No lead byte within the last 4 bytes → malformed tail; decode it all.
            return count
        }

        let expected: Int
        switch buf[i] {
        case 0x00...0x7F: expected = 1   // ASCII
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        default:          expected = 1   // stray continuation / invalid lead
        }

        let have = count - i
        // A multi-byte sequence whose continuation bytes haven't all arrived yet.
        if expected > 1 && have < expected {
            return i
        }
        return count
    }
}
