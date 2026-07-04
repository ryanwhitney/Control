import Testing
@testable import Control

/// Unit tests for the split-safe UTF-8 stream decoder. These guard the real
/// encoding hazard on the streaming transport: SSH/TCP can split a multi-byte
/// character (emoji, CJK, accented Latin) between two channel reads, and decoding
/// each read on its own would corrupt it. The decoder is byte-based and
/// transport-independent, so no SSH is needed.
struct UTF8StreamDecoderTests {

    /// A 4-byte emoji split across two chunks reassembles into one grapheme.
    @Test func emojiSplitAcrossChunks() {
        var d = UTF8StreamDecoder()
        let emoji = Array("🎵".utf8)              // F0 9F 8E B5
        #expect(d.decode(Array(emoji[0..<2])) == "")   // incomplete → held back
        #expect(d.decode(Array(emoji[2...])) == "🎵")  // continuation completes it
    }

    /// A 3-byte CJK character split 1+2 reassembles.
    @Test func cjkSplitOneTwo() {
        var d = UTF8StreamDecoder()
        let bytes = Array("日".utf8)              // E6 97 A5
        #expect(d.decode([bytes[0]]) == "")
        #expect(d.decode(Array(bytes[1...])) == "日")
    }

    /// A 2-byte accented Latin character split down the middle reassembles.
    @Test func accentedLatinSplit() {
        var d = UTF8StreamDecoder()
        let bytes = Array("é".utf8)               // C3 A9
        #expect(d.decode([bytes[0]]) == "")
        #expect(d.decode([bytes[1]]) == "é")
    }

    /// ASCII passes straight through with no buffering.
    @Test func asciiPassThrough() {
        var d = UTF8StreamDecoder()
        #expect(d.decode(Array("=> \"hi\"\n".utf8)) == "=> \"hi\"\n")
    }

    /// A chunk that already ends on a code-point boundary is emitted whole (the
    /// decoder must not over-hold a complete trailing multi-byte character).
    @Test func completeMultibyteNotHeld() {
        var d = UTF8StreamDecoder()
        #expect(d.decode(Array("café 日本語 🎵".utf8)) == "café 日本語 🎵")
    }

    /// An ASCII prefix streams immediately even when a partial character trails
    /// it; the partial waits for its continuation bytes.
    @Test func prefixEmittedTrailingPartialHeld() {
        var d = UTF8StreamDecoder()
        let emoji = Array("🎶".utf8)              // F0 9F 8E B6
        let chunk = Array("Now: ".utf8) + [emoji[0]]
        #expect(d.decode(chunk) == "Now: ")       // holds the lone lead byte
        #expect(d.decode(Array(emoji[1...])) == "🎶")
    }

    /// A character split across *three* single-byte chunks still reassembles.
    @Test func emojiSplitByteByByte() {
        var d = UTF8StreamDecoder()
        let emoji = Array("🎧".utf8)              // 4 bytes
        #expect(d.decode([emoji[0]]) == "")
        #expect(d.decode([emoji[1]]) == "")
        #expect(d.decode([emoji[2]]) == "")
        #expect(d.decode([emoji[3]]) == "🎧")
    }

    /// reset() drops a buffered partial sequence so it can't corrupt later text.
    @Test func resetClearsRemainder() {
        var d = UTF8StreamDecoder()
        _ = d.decode(Array(Array("🎵".utf8)[0..<2]))   // buffer a partial emoji
        d.reset()
        #expect(d.decode(Array("A".utf8)) == "A")       // no stale prefix leaks in
    }

    /// An empty chunk never completes a held sequence and emits nothing.
    @Test func emptyChunkHoldsPartial() {
        var d = UTF8StreamDecoder()
        let emoji = Array("🎵".utf8)
        #expect(d.decode(Array(emoji[0..<2])) == "")
        #expect(d.decode([]) == "")                     // still waiting
        #expect(d.decode(Array(emoji[2...])) == "🎵")
    }
}
