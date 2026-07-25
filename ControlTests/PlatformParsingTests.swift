import Testing
import Foundation
@testable import Control

/// Most platforms delegate to the *same* `parseSeparatedState`, so that contract
/// is tested once rather than re-tested per app. Only genuine differences get
/// their own case. Real end-to-end output is covered by the live suite.
struct PlatformParsingTests {
    private let sep = ScriptTokens.fieldSeparator

    /// Music stands in for every default-offset platform.
    @Test func separatedStatusExtractsAndTrimsFields() {
        #expect(MusicApp().parseState("  Plans \(sep) Dinosaur Jr. \(sep) true ")
                == AppState(title: "Plans", subtitle: "Dinosaur Jr.", isPlaying: true, error: nil))
    }

    /// An exact lowercase match: the scripts only ever emit lowercase booleans.
    @Test func playStateIsExactLowercaseTrue() {
        #expect(MusicApp().parseState("T\(sep)S\(sep)true").isPlaying == true)
        #expect(MusicApp().parseState("T\(sep)S\(sep)True").isPlaying == false)
        #expect(MusicApp().parseState("T\(sep)S\(sep)1").isPlaying == false)
    }

    /// Too few fields → nil, and the platform falls back to its error state.
    @Test func tooFewFieldsYieldNoPlayState() {
        let state = MusicApp().parseState("just one chunk")
        #expect(state.isPlaying == nil)
        #expect(state.error != nil)
    }

    /// VLC's boolean is at index 3. Field 2 is the word "paused" and field 3 is
    /// "true", so reading the default index would flip the result.
    @Test func vlcReadsPlayStateFromItsExtraColumn() {
        #expect(VLCApp().parseState("Big Buck Bunny\(sep) \(sep)paused\(sep)true").isPlaying == true)
        #expect(VLCApp().parseState("Big Buck Bunny\(sep) \(sep)playing\(sep)false").isPlaying == false)
    }

    /// Safari alone shows a separator-less line as the title rather than an
    /// error — a deliberate leniency the shared parser doesn't have.
    @Test func safariSurfacesBareLineAsTitle() {
        let state = SafariApp().parseState("No video found here")
        #expect(state.title == "No video found here")
        #expect(state.isPlaying == nil)
        #expect(state.error == nil)
    }

    /// Nothing on that page plays, so the shared parser's boolean is discarded
    /// rather than read downstream as "paused". The middle field is empty but
    /// must still be present for the parse to reach the third.
    @Test func keyboardReportsFrontAppWithoutPlayState() {
        let state = KeyboardApp().parseState("Safari\(sep)\(sep)false")
        #expect(state.title == "Safari")
        #expect(state.subtitle == "")
        #expect(state.isPlaying == nil)
    }

    /// The status read only needs Automation; the pad also needs assistive
    /// access, so the script reports that itself rather than letting a healthy
    /// readout contradict a refused key press.
    @Test func keyboardStatusGuardsOnAssistiveAccess() {
        let script = KeyboardApp().fetchState()
        #expect(script.contains("UI elements enabled"))
        #expect(script.contains(ScriptTokens.accessibilityRequired))
    }

    /// This read is the pad's only permission signal, so both `try` blocks have
    /// to let a denied prompt back out instead of degrading to a blank field.
    @Test func keyboardStatusRethrowsPermissionDenial() {
        let script = KeyboardApp().fetchState()
        let tryBlocks = script.components(separatedBy: "end try").count - 1
        let reraises = script.components(separatedBy: "then error errorMessage number errorNumber").count - 1
        #expect(tryBlocks == 2)
        #expect(reraises == tryBlocks)
    }
}
