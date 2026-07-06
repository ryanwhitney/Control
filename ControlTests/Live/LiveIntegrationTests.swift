import Testing
import Foundation
@testable import Control

extension Tag {
    /// Marks tests that hit a real Mac over real SSH. Filter with
    /// `--tag live` / skip with `--skip-tag live`.
    @Tag static var live: Self
}

/// Live integration against a real Mac (this dev machine by default). Runs the
/// actual generated AppleScript over the production SSH transport and asserts on
/// real behavior — volume actually moves, a play/pause actually flips state, a
/// status script actually parses — the coverage the pure-Swift tests can't give.
///
/// The whole suite is inert unless `VC_LIVE=1` and credentials are set (see
/// `LiveEnvironment` and `ControlTests/Live/Fixtures.md`). Run
/// `Scripts/live-setup.sh` first to put the Mac into the state the action tests
/// expect. Connections come from the shared `LivePool` (one per transport,
/// reused). A platform whose app isn't running — or has no media loaded — is
/// skipped via `liveSkip` (loud in the log; a failure under `VC_LIVE_STRICT=1`).
///
/// `.serialized`: every test mutates one shared Mac (system volume, playback,
/// foregrounded app), so the default parallel execution would let cases stomp
/// each other. This also covers the `AppController` tests declared in the
/// extension in `LiveAppControllerTests.swift`.
/// `.timeLimit`: a wedged PTY or hung osascript must surface as a named failure,
/// not stall the suite forever.
@Suite(.serialized, .enabled(if: LiveEnvironment.isEnabled), .tags(.live), .timeLimit(.minutes(2)))
struct LiveIntegrationTests {

    // MARK: - Transport engine

    /// End-to-end proof of the whole engine on both transports: read the volume,
    /// set it to a known value, read it back, then restore. Exercises the real
    /// `SSHClient`/`LegacySSHClient` → ChannelExecutor → PTY → parser path.
    @Test(arguments: LiveEnvironment.Transport.allCases)
    func volumeRoundTrip(_ transport: LiveEnvironment.Transport) async throws {
        let env = try await LivePool.shared.env(transport)

        let original = try await env.run("output volume of (get volume settings)")
        guard let originalInt = Int(original) else {
            Issue.record("volume output not numeric: '\(original)'")
            return
        }
        let target = originalInt >= 50 ? 30 : 70
        _ = try await env.run("set volume output volume \(target)")
        let after = try await env.run("output volume of (get volume settings)")
        #expect(Int(after) == target, "set \(target) but Mac reported \(after) over \(transport)")

        _ = try await env.run("set volume output volume \(originalInt)")   // restore
    }

    /// Every one of a burst of concurrent commands on the compatibility
    /// transport must get exactly its own reply back — the contract that eager
    /// completion (first output chunk, then the exit-status event) violated,
    /// surfacing in the field as empty or crossed replies whenever commands
    /// overlapped (mismatched heartbeats → spurious reconnect loops).
    @Test func legacyConcurrentRepliesStaySeparate() async throws {
        let env = try await LivePool.shared.env(.compatibility)
        try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
            for i in 0..<10 {
                let token = "VC7LIVE_CONCURRENCY_\(i)_\(UInt32.random(in: 0..<UInt32.max))"
                group.addTask {
                    let reply = try await env.run("return \"\(token)\"")
                    return (i, token, reply)
                }
            }
            for try await (i, token, reply) in group {
                #expect(reply == token, "command \(i) got '\(reply)' instead of its own token")
            }
        }
    }

    /// A real manager (transport + heartbeat + recovery state machine) must
    /// stay `.connected` while user-style command bursts overlap the heartbeat.
    /// This is the layer the per-command tests bypass — where completion races
    /// surfaced as recover/reconnect loops. Point `VC_LIVE_HOST` at another Mac
    /// over Wi-Fi to exercise real network RTTs.
    @Test(arguments: LiveEnvironment.Transport.allCases)
    @MainActor
    func heartbeatStaysConnectedUnderLoad(_ transport: LiveEnvironment.Transport) async throws {
        guard let user = LiveEnvironment.value("VC_LIVE_USER"), !user.isEmpty,
              let pass = LiveEnvironment.value("VC_LIVE_PASS"), !pass.isEmpty else {
            Issue.record("VC_LIVE_USER / VC_LIVE_PASS not set")
            return
        }
        let host = LiveEnvironment.value("VC_LIVE_HOST") ?? "127.0.0.1"

        // The manager picks its transport from preferences on connect.
        let previousMethod = UserPreferences.shared.connectionMethod
        UserPreferences.shared.connectionMethod = transport == .streaming ? .streaming : .compatibility
        defer { UserPreferences.shared.connectionMethod = previousMethod }

        let manager = SSHConnectionManager()
        try await manager.connect(host: host, username: user, password: pass)
        manager.startHeartbeat()
        defer {
            manager.stopHeartbeat()
            manager.disconnect()
        }

        // ~4 s of overlapping volume reads while the heartbeat pings underneath.
        for _ in 0..<10 {
            manager.executeCommand(onChannel: "system",
                                   "output volume of (get volume settings)",
                                   description: "load-test volume read") { _ in }
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(manager.connectionState == .connected,
                    "state left .connected under load on \(transport): \(manager.connectionState.description)")
        }
    }

    // MARK: - Status against real apps

    /// For every platform whose app is running, the real `combinedStatusScript()`
    /// must execute cleanly and parse into a non-error state. This is what
    /// catches AppleScript property/format drift across app and OS versions — a
    /// renamed property or changed output shape fails here, where the old
    /// script-substring tests would still pass. Apps that aren't running skip.
    /// Experimental platforms (Safari) are excluded — their scripts are
    /// best-effort by design and not held to automated coverage.
    @Test(arguments: PlatformRegistry.allPlatforms.filter { !$0.experimental }.map { $0.id })
    func statusScriptRunsAndParses(_ platformId: String) async throws {
        guard let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) else {
            Issue.record("unknown platform id '\(platformId)'")
            return
        }
        let env = try await LivePool.shared.env()
        guard try await env.isAppRunning(platform.name) else {
            return liveSkip("\(platform.name) status", "app is not running — run Scripts/live-setup.sh")
        }

        let output = try await env.run(platform.combinedStatusScript(), channelKey: platform.id)

        #expect(!output.contains("Not authorized to send Apple events"),
                "Grant Automation permission to sshd for \(platform.name) (System Settings › Privacy & Security › Automation)")
        #expect(!output.lowercased().contains("execution error"),
                "\(platform.name) status script errored: \(output)")

        if output == ScriptTokens.notRunning { return }
        let state = platform.parseState(output)
        #expect(state.error == nil, "\(platform.name) status did not parse: '\(output)'")
    }

    // MARK: - Actions change real state

    /// Play/pause on each scriptable player must flip the parsed `isPlaying`,
    /// with any settling wrapper making the status read reflect the *new* state
    /// rather than the pre-toggle one. Restores when done. Music/Spotify go
    /// through `player state` + the settling poll; QuickTime toggles
    /// `playing of document 1`; VLC toggles via its `play` command and reads the
    /// boolean from its extra column.
    @Test func musicPlayPauseFlipsState() async throws {
        try await assertPlayPauseFlips(MusicApp())
    }

    @Test func spotifyPlayPauseFlipsState() async throws {
        try await assertPlayPauseFlips(SpotifyApp())
    }

    @Test func quickTimePlayPauseFlipsState() async throws {
        try await assertPlayPauseFlips(QuickTimeApp())
    }

    @Test func vlcPlayPauseFlipsState() async throws {
        try await assertPlayPauseFlips(VLCApp())
    }

    /// Next-track on Music must actually advance to a different track, with the
    /// status read reflecting the new track (the whole point of the track-change
    /// settling poll). Guarded to a multi-track context so a single-track/
    /// repeat-one queue — where the title can't change — is skipped, then
    /// restored with previous-track.
    @Test func musicNextTrackAdvances() async throws {
        let env = try await LivePool.shared.env()
        let music = MusicApp()
        guard let before = try await env.loadedState(music) else {
            return liveSkip("Music next-track", "Music is not running or has nothing loaded — run Scripts/live-setup.sh")
        }
        guard let trackCount = try await intResult("tell application \"Music\" to return (count of tracks of current playlist)", channelKey: music.id, env: env),
              trackCount > 1 else {
            return liveSkip("Music next-track", "current playlist has ≤ 1 track, so the title can't change")
        }

        let after = music.parseState(try await env.run(music.actionWithStatus(.nextTrack), channelKey: music.id))

        #expect(after.isPlaying != nil, "status after next-track did not parse")
        #expect(after.title != before.title || after.subtitle != before.subtitle,
                "next-track did not advance: still '\(before.title)'")

        _ = try await env.run(music.actionWithStatus(.previousTrack), channelKey: music.id)   // restore
    }

    // MARK: - Helpers

    /// Shared play/pause flip assertion: read the platform's own parsed status
    /// for the before-state (so the same probe works for `player state` apps and
    /// document/`playing`-property apps alike), toggle, expect the flip, then
    /// toggle back. Skips when the app is down or has nothing loaded.
    private func assertPlayPauseFlips(_ platform: some AppPlatform) async throws {
        let env = try await LivePool.shared.env()
        guard let before = try await env.loadedState(platform) else {
            return liveSkip("\(platform.name) play/pause", "app is not running or has no media loaded — run Scripts/live-setup.sh")
        }
        let wasPlaying = before.isPlaying == true

        let after = platform.parseState(try await env.run(platform.actionWithStatus(.playPauseToggle), channelKey: platform.id))
        #expect(after.isPlaying == !wasPlaying,
                "\(platform.name) play/pause did not flip \(wasPlaying) → \(String(describing: after.isPlaying))")

        _ = try await env.run(platform.actionWithStatus(.playPauseToggle), channelKey: platform.id)   // restore
    }

    private func intResult(_ script: String, channelKey: String, env: LiveEnvironment) async throws -> Int? {
        Int(try await env.run(script, channelKey: channelKey))
    }
}
