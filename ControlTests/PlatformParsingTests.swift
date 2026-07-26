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

    /// The guard costs ~10ms a poll to catch a condition that's permanent once
    /// fixed, so the controller drops it after a clean read. Everything else in
    /// the script has to survive that.
    @Test func keyboardStatusCanDropTheAssistiveAccessGuard() {
        let guarded = KeyboardApp().combinedStatusScript(assumingAssistiveAccess: false)
        let unguarded = KeyboardApp().combinedStatusScript(assumingAssistiveAccess: true)

        #expect(guarded.contains("UI elements enabled"))
        #expect(!unguarded.contains("UI elements enabled"))
        #expect(!unguarded.contains(ScriptTokens.accessibilityRequired))
        // The parse the readout depends on is untouched either way.
        for script in [guarded, unguarded] {
            #expect(script.contains("path to frontmost application"))
            #expect(script.components(separatedBy: "set AppleScript's text item delimiters to savedDelims").count - 1 == 2)
            #expect(script.hasPrefix("tell application \"System Events\""))
            #expect(script.hasSuffix("end tell"))
        }
    }

    /// Delimiters are global to the interpreter and Fast keeps one alive per
    /// channel, so the save must sit above the `try` and the restore must run on
    /// both paths — otherwise a thrown error leaks ":" for the whole session.
    @Test func keyboardStatusRestoresDelimitersOnBothPaths() {
        let script = KeyboardApp().fetchState()
        let save = "set savedDelims to AppleScript's text item delimiters"
        let restore = "set AppleScript's text item delimiters to savedDelims"
        #expect(script.components(separatedBy: restore).count - 1 == 2)
        guard let saveIndex = script.range(of: save)?.lowerBound,
              let tryIndex = script.range(of: "try")?.lowerBound else {
            Issue.record("status script no longer saves delimiters or opens a try")
            return
        }
        #expect(saveIndex < tryIndex)
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
