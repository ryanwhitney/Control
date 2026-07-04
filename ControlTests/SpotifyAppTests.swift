import Testing
@testable import Control

/// Guards Spotify's track-change handling: next/previous poll until the track id
/// settles (Spotify returns before `current track` updates and the new track may
/// load from the network), while play/pause reads immediately (no settle delay).
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

    @Test func playPauseReadsImmediately() {
        let script = spotify.actionWithStatus(.playPauseToggle)
        #expect(script.contains("playpause"))
        // Play/pause reads immediately: no settle delay and no track poll.
        #expect(!script.contains("delay 0.3"))
        #expect(!script.contains("id of current track"))
        #expect(!script.contains("exit repeat"))
    }
}
