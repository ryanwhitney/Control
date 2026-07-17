import Testing
@testable import Control

/// Unit coverage for status parsing. Music, Spotify, TV, QuickTime and Safari all
/// delegate to the *same* `parseSeparatedState` (title | subtitle | isPlaying),
/// so that shared contract is tested once here rather than re-tested per app with
/// a different song/movie name. Only the genuine per-platform differences get
/// their own case: VLC reads the boolean from an extra column, and Safari has a
/// distinct fallback, and Keyboard suppresses a redundant window title. Each
/// app's real end-to-end output is separately validated by the live
/// `statusScriptRunsAndParses`.
struct PlatformParsingTests {
    private let sep = ScriptTokens.fieldSeparator

    /// The shared three-field contract: field 0/1 become title/subtitle, the
    /// play flag comes from field 2, and every field is trimmed. Music stands in
    /// for all default-offset platforms since they run identical parsing.
    @Test func separatedStatusExtractsAndTrimsFields() {
        #expect(MusicApp().parseState("  Plans \(sep) Dinosaur Jr. \(sep) true ")
                == AppState(title: "Plans", subtitle: "Dinosaur Jr.", isPlaying: true, error: nil))
    }

    /// `isPlaying` is an exact lowercase `"true"` match — the scripts only ever
    /// emit lowercase booleans, and anything else must read as not-playing.
    @Test func playStateIsExactLowercaseTrue() {
        #expect(MusicApp().parseState("T\(sep)S\(sep)true").isPlaying == true)
        #expect(MusicApp().parseState("T\(sep)S\(sep)True").isPlaying == false)
        #expect(MusicApp().parseState("T\(sep)S\(sep)1").isPlaying == false)
    }

    /// Too few fields for the play index → no confident play state (parser
    /// returns nil and the platform falls back to an error/unknown state).
    @Test func tooFewFieldsYieldNoPlayState() {
        let state = MusicApp().parseState("just one chunk")
        #expect(state.isPlaying == nil)
        #expect(state.error != nil)
    }

    /// VLC's output carries an extra state-word column, so its boolean is at
    /// index 3. This pins that offset: field 2 here is the word "paused" while
    /// field 3 is "true", and VLC must report *playing* — proof it isn't reading
    /// the default index 2 (which would flip the result).
    @Test func vlcReadsPlayStateFromItsExtraColumn() {
        #expect(VLCApp().parseState("Big Buck Bunny\(sep) \(sep)paused\(sep)true").isPlaying == true)
        #expect(VLCApp().parseState("Big Buck Bunny\(sep) \(sep)playing\(sep)false").isPlaying == false)
    }

    /// Safari alone surfaces a separator-less line (e.g. a JS status message) as
    /// the title instead of an error — a deliberate leniency the shared parser
    /// doesn't have.
    @Test func safariSurfacesBareLineAsTitle() {
        let state = SafariApp().parseState("No video found here")
        #expect(state.title == "No video found here")
        #expect(state.isPlaying == nil)
        #expect(state.error == nil)
    }

    /// Keyboard reports the frontmost app plus its window title, and never a play
    /// state — nothing on that page plays, so the shared parser's boolean must be
    /// discarded rather than read downstream as "paused".
    @Test func keyboardReportsFrontAppAndWindowWithoutPlayState() {
        let state = KeyboardApp().parseState("Safari\(sep)Young Washington Review - YouTube\(sep)false")
        #expect(state.title == "Safari")
        #expect(state.subtitle == "Young Washington Review - YouTube")
        #expect(state.isPlaying == nil)
    }

    /// A window title the app name already says is dropped: identical to it
    /// ("Calendar"), or wholly contained in it ("Chrome" under "Google Chrome").
    /// Matching ignores case and surrounding whitespace.
    @Test func keyboardDropsWindowTitleTheAppNameAlreadySays() {
        #expect(KeyboardApp.windowSubtitle("Calendar", appName: "Calendar") == "")
        #expect(KeyboardApp.windowSubtitle("Chrome", appName: "Google Chrome") == "")
        #expect(KeyboardApp.windowSubtitle("  calendar  ", appName: "Calendar") == "")
        #expect(KeyboardApp.windowSubtitle("", appName: "TV") == "")
    }

    /// A *longer* title survives even though it contains the app name — the
    /// remainder is real information, which is the whole reason for the subtitle.
    @Test func keyboardKeepsWindowTitleThatAddsInformation() {
        #expect(KeyboardApp.windowSubtitle("Activity Monitor – All Processes", appName: "Activity Monitor")
                == "Activity Monitor – All Processes")
        #expect(KeyboardApp.windowSubtitle("No file - mpv", appName: "mpv") == "No file - mpv")
    }
}
