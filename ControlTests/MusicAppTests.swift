import Testing
@testable import Control

/// Guards the Music track-change fix: `next track`/`previous track` return before
/// Music updates `current track`, so the combined action+status script must wait
/// for the track id to actually change before reading state, or the UI shows the
/// previous track until the next refresh. Play/pause doesn't change the track and
/// must stay a plain immediate read (no wait), so we don't regress its latency.
struct MusicAppTests {
    private let music = MusicApp()

    @Test func nextTrackWaitsForTrackChange() {
        let script = music.actionWithStatus(.nextTrack)
        #expect(script.contains("next track"))
        // Records the pre-action track id and polls until it changes.
        #expect(script.contains("id of current track"))
        #expect(script.contains("repeat"))
        #expect(script.contains("exit repeat"))
        // Still reads status in the same Music tell block.
        #expect(script.contains("name of current track"))
    }

    @Test func previousTrackWaitsForTrackChange() {
        let script = music.actionWithStatus(.previousTrack)
        #expect(script.contains("previous track"))
        #expect(script.contains("id of current track"))
        #expect(script.contains("exit repeat"))
    }

    @Test func playPauseReadsImmediately() {
        let script = music.actionWithStatus(.playPauseToggle)
        #expect(script.contains("playpause"))
        // No track-change: must not add the poll loop or its per-iteration delay.
        #expect(!script.contains("repeat"))
        #expect(!script.contains("id of current track"))
    }
}
