import Testing
@testable import Control

/// Guards Spotify's action handling: next/previous poll until the track id
/// settles, and play/pause polls until the player state flips. Spotify updates
/// both a beat after the command returns, so reading immediately would report
/// the pre-action state.
struct SpotifyAppTests {
    private let spotify = SpotifyApp()

    @Test func nextTrackPollsUntilTrackChanges() {
        let script = spotify.actionWithStatus(.nextTrack)
        #expect(script.contains("next track"))
        #expect(script.contains("id of current track"))
        #expect(script.contains("exit repeat"))
        // No leftover blanket settle delay on the track-change path.
        #expect(!script.contains("delay 0.3"))
    }

    @Test func previousTrackPollsUntilTrackChanges() {
        let script = spotify.actionWithStatus(.previousTrack)
        #expect(script.contains("previous track"))
        #expect(script.contains("id of current track"))
        #expect(script.contains("exit repeat"))
    }

    @Test func playPauseWaitsForStateChange() {
        let script = spotify.actionWithStatus(.playPauseToggle)
        #expect(script.contains("playpause"))
        // Polls until player state flips so the status read reflects the toggle.
        #expect(script.contains("player state is not previousPlayerState"))
        #expect(script.contains("exit repeat"))
        // A play-state poll, not a track-change poll.
        #expect(!script.contains("id of current track"))
    }
}
