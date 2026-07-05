import Testing
@testable import Control

/// Guards Music's action+status settling: `next track`/`previous track` wait for
/// the track id to change, and play/pause waits for the player state to flip,
/// before the status is read. Music can report the pre-action value otherwise.
/// Both polls exit the instant the state updates, so a synchronous player pays
/// no latency.
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

    @Test func playPauseWaitsForStateChange() {
        let script = music.actionWithStatus(.playPauseToggle)
        #expect(script.contains("playpause"))
        // Polls until the player state flips, not the track id.
        #expect(script.contains("player state is not previousPlayerState"))
        #expect(script.contains("exit repeat"))
        #expect(!script.contains("id of current track"))
    }
}
