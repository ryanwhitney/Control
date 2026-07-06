import Testing
@testable import Control

/// Privacy regression tests for the debug-log media sanitizer: real media
/// titles must be redacted even when they contain status words, while exact
/// system values stay readable.
@MainActor
struct DebugLoggerSanitizerTests {
    private let sep = ScriptTokens.fieldSeparator

    @Test func mediaTitleContainingStatusWordIsRedacted() {
        let output = DebugLogger.shared.sanitizeMediaContent("Playing God\(sep)Artist Name\(sep)true")
        #expect(!output.contains("Playing God"))
        #expect(!output.contains("Artist Name"))
        #expect(output.contains("Pl***"))
    }

    @Test func exactSystemValuesPassThroughUnredacted() {
        let message = "Not running\(sep)   \(sep)false"
        #expect(DebugLogger.shared.sanitizeMediaContent(message) == message)
    }

    @Test func fullOutputPayloadIsRedacted() {
        let output = DebugLogger.shared.sanitizeMediaContent("Full output: My Secret Song\(sep)Private Artist\(sep)true")
        #expect(output.hasPrefix("Full output: "))
        #expect(!output.contains("My Secret Song"))
        #expect(!output.contains("Private Artist"))
    }
}
