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
}
