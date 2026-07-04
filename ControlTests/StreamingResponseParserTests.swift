import Testing
@testable import Control

/// Unit tests for the SSH streaming-response framing. These guard the bugs that
/// bit us during bring-up — most importantly the `\r\n` grapheme-cluster line
/// split, prompt-prefix stripping with echo off, and timeout not misrouting the
/// next command. The parser is transport-independent, so no SSH is needed.
struct StreamingResponseParserTests {

    /// Regression: over a PTY, ONLCR emits "\r\n", which is a single Swift
    /// Character — `firstIndex(of:"\n")` never matched, so nothing parsed.
    @Test func crlfWarmupCompletes() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0000_END"
        p.addCommand(sentinel: s)
        var out: [StreamingResponseParser.Completion] = []
        for chunk in [
            "-- 0000 warm-up\r\nreturn 0\r\n\r\n\"\(s)\"\r\n\r\n",
            ">> ", "=> \r\n>> ", "=> 0\r\n>> ", ">> ", "=> \"\(s)\"\r\n>> "
        ] { out += p.ingest(chunk) }
        #expect(out.count == 1)
        #expect(out.first?.output == "0")
        #expect(out.first?.isError == false)
    }

    /// Result line survives stacked `>> >> ` prompts (echo-off behaviour).
    @Test func stackedPromptsAndFieldResult() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0001_END"
        p.addCommand(sentinel: s)
        let out = p.ingest("=> \"Some Song~|VCF|~Artist~|VCF|~true\"\r\n>> >> => \"\(s)\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.output == "Some Song~|VCF|~Artist~|VCF|~true")
    }

    /// AppleScript errors are returned as output (channel stays warm), flagged.
    @Test func appleScriptErrorReturnedAsOutput() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0002_END"
        p.addCommand(sentinel: s)
        let out = p.ingest(">> !! Not authorized to send Apple events\r\n>> => \"\(s)\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.isError == true)
        #expect(out.first?.output.contains("Not authorized") == true)
    }

    /// Sentinel split across two reads still matches once whole.
    @Test func sentinelSplitAcrossReads() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0003_END"
        p.addCommand(sentinel: s)
        #expect(p.ingest("=> \"42\"\r\n>> => \"VC7CTRL_ABC").isEmpty)
        let out = p.ingest("_0003_END\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.output == "42")
    }

    /// A timed-out command is removed so the next command isn't misrouted into
    /// its stale buffer (the desync cascade we fixed).
    @Test func timeoutDoesNotMisrouteNextCommand() {
        var p = StreamingResponseParser()
        let a = "VC7CTRL_ABC_0004_END", b = "VC7CTRL_ABC_0005_END"
        p.addCommand(sentinel: a)
        p.removeCommand(sentinel: a)       // simulate timeout
        p.addCommand(sentinel: b)
        let out = p.ingest("=> \"live\"\r\n=> \"\(b)\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.sentinel == b)
        #expect(out.first?.output == "live")
    }

    /// Output with no command pending is ignored (startup banner / late data).
    @Test func strayOutputIgnoredWhenIdle() {
        var p = StreamingResponseParser()
        #expect(p.ingest("Last login: ...\r\n=> \"orphan\"\r\n").isEmpty)
    }

    @Test func unquoteStringsNumbersAndEscapes() {
        #expect(StreamingResponseParser.unquote("\"hi\"") == "hi")
        #expect(StreamingResponseParser.unquote("\"a \\\"b\\\" c\"") == "a \"b\" c")
        #expect(StreamingResponseParser.unquote("42") == "42")
        #expect(StreamingResponseParser.unquote("true") == "true")
        // Control-char escapes from `osascript -s s` must round-trip, not drop.
        #expect(StreamingResponseParser.unquote("\"a\\tb\"") == "a\tb")
        #expect(StreamingResponseParser.unquote("\"x\\ny\"") == "x\ny")
    }

    @Test func stripPromptsLeavesInnerAngles() {
        #expect(StreamingResponseParser.stripPrompts(">> >> => \">>>x<<<\"") == "=> \">>>x<<<\"")
        #expect(StreamingResponseParser.stripPrompts("?> ?> => \"y\"") == "=> \"y\"")
    }

    // MARK: - Encoding & locale
    //
    // Media titles, artist names and device names travel through the same text
    // stream we parse, so non-ASCII content (emoji, CJK, accented Latin,
    // combining marks) must survive framing untouched. `osascript -s s` emits
    // these characters literally inside the quotes, so the parser must not trim,
    // split or mangle them.

    /// Non-ASCII results round-trip through `unquote` without mangling graphemes.
    @Test func unquotePreservesUnicode() {
        #expect(StreamingResponseParser.unquote("\"café\"") == "café")
        #expect(StreamingResponseParser.unquote("\"日本語のタイトル\"") == "日本語のタイトル")
        #expect(StreamingResponseParser.unquote("\"🎵 Song 🎶\"") == "🎵 Song 🎶")
        // Base letter + combining acute (U+0301) must stay a single grapheme.
        #expect(StreamingResponseParser.unquote("\"e\u{0301}\"") == "e\u{0301}")
        // Escaped quotes inside a non-ASCII value still unescape correctly.
        #expect(StreamingResponseParser.unquote("\"Über \\\"Café\\\"\"") == "Über \"Café\"")
    }

    /// A full non-ASCII result line completes and yields the exact string.
    @Test func ingestCompletesUnicodeResult() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0100_END"
        p.addCommand(sentinel: s)
        let title = "🎧 Étude — 日本語 café"
        let out = p.ingest("=> \"\(title)\"\r\n=> \"\(s)\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.output == title)
    }

    /// A result split mid-value across two ingests (Unicode on both sides of the
    /// boundary) is reassembled from the line buffer.
    @Test func unicodeResultSplitAcrossIngests() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0101_END"
        p.addCommand(sentinel: s)
        #expect(p.ingest("=> \"Café ").isEmpty)          // no newline yet
        let out = p.ingest("日本語 🎵\"\r\n=> \"\(s)\"\r\n")
        #expect(out.count == 1)
        #expect(out.first?.output == "Café 日本語 🎵")
    }

    /// Field-delimited payloads (the `~|VCF|~` separator apps use) survive with
    /// non-ASCII fields intact.
    @Test func delimitedUnicodeFieldsSurvive() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0102_END"
        p.addCommand(sentinel: s)
        let value = "Café del Mar~|VCF|~Ólafur Arnalds~|VCF|~true"
        let out = p.ingest("=> \"\(value)\"\r\n=> \"\(s)\"\r\n")
        #expect(out.first?.output == value)
    }

    /// The interpreter's markers (`=> `, `!! `, `>> `) *inside* a quoted value are
    /// content, not framing — a song literally titled "=> hi" must be preserved.
    @Test func markersInsideValuePreserved() {
        var p = StreamingResponseParser()
        let s = "VC7CTRL_ABC_0103_END"
        p.addCommand(sentinel: s)
        let out = p.ingest("=> \"=> !! >> not markers\"\r\n=> \"\(s)\"\r\n")
        #expect(out.first?.output == "=> !! >> not markers")
    }

    /// Unusual Unicode whitespace *inside* the quotes is content and must not be
    /// trimmed — only the outer framing whitespace is stripped.
    @Test func interiorUnicodeWhitespacePreserved() {
        // U+00A0 NO-BREAK SPACE surrounding the value, inside the quotes.
        #expect(StreamingResponseParser.unquote("\"\u{00A0}spaced\u{00A0}\"") == "\u{00A0}spaced\u{00A0}")
    }
}
