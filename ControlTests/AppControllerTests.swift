import Testing
import Foundation
@testable import Control

/// Drives `AppController` through an injected `FakeSSHClient` so the
/// orchestration layer — status parsing, sentinel/permission handling, refresh
/// dedup, volume coalescing, and action rate limiting — is exercised without a
/// real Mac. These are the timing/concurrency-heavy paths the static
/// script-content tests can't reach; they stay hermetic (no network, no sleeps
/// beyond the volume coalescer's own interval) so they belong in the default
/// suite.
@MainActor
struct AppControllerTests {
    private let sep = ScriptTokens.fieldSeparator

    private func makeController(_ fake: FakeSSHClient, platforms: [any AppPlatform], enabled: Set<String>? = nil) -> AppController {
        let registry = PlatformRegistry(platforms: platforms)
        if let enabled { registry.enabledPlatforms = enabled }   // pin active set (ignore persisted defaults)
        return AppController(sshClient: fake, platformRegistry: registry)
    }

    private func volumeAwareFake() -> FakeSSHClient {
        let fake = FakeSSHClient()
        fake.responder = { channelKey, _ in channelKey == "system" ? .success("50") : .success(ScriptTokens.notRunning) }
        return fake
    }

    // MARK: - Status parsing

    @Test func notRunningSentinelShowsNotRunning() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success(ScriptTokens.notRunning) }
        let controller = makeController(fake, platforms: [MusicApp()])

        await controller.updateState(for: MusicApp(), force: true)

        #expect(controller.states["music"]?.title == "Not running")
        #expect(controller.states["music"]?.isPlaying == nil)
    }

    @Test func permissionErrorShowsPermissionsRequired() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success("Not authorized to send Apple events") }
        let controller = makeController(fake, platforms: [MusicApp()])

        await controller.updateState(for: MusicApp(), force: true)

        #expect(controller.states["music"]?.title == "Permissions Required")
    }

    @Test func parsesSeparatedPlayingState() async {
        let fake = FakeSSHClient()
        fake.responder = { [sep] _, _ in .success("Song\(sep)Artist\(sep)true") }
        let controller = makeController(fake, platforms: [MusicApp()])

        await controller.updateState(for: MusicApp(), force: true)

        let state = controller.states["music"]
        #expect(state?.title == "Song")
        #expect(state?.subtitle == "Artist")
        #expect(state?.isPlaying == true)
    }

    /// A non-forced refresh within the 2 s window must be skipped, not re-sent.
    @Test func refreshIsDedupedWithinTwoSeconds() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success(ScriptTokens.notRunning) }
        let controller = makeController(fake, platforms: [MusicApp()])

        await controller.updateState(for: MusicApp())   // first: runs
        await controller.updateState(for: MusicApp())   // within 2 s: skipped

        #expect(fake.commands(on: "music").count == 1)
    }

    // MARK: - Volume

    @Test func systemVolumeIsParsedFromOutput() async {
        let fake = FakeSSHClient()
        fake.responder = { channelKey, _ in
            channelKey == "system" ? .success("42") : .success(ScriptTokens.notRunning)
        }
        let controller = makeController(fake, platforms: [MusicApp()])

        await controller.updateAllStates()

        #expect(abs((controller.currentVolume ?? -1) - 0.42) < 0.001)
    }

    /// Rapid slider updates coalesce to a single send carrying the latest value.
    @Test func setVolumeCoalescesToLatestValue() async throws {
        let fake = FakeSSHClient()
        let controller = makeController(fake, platforms: [MusicApp()])

        controller.setVolume(0.25)
        controller.setVolume(0.50)
        controller.setVolume(0.75)   // 0.75 is exact in binary → Int(75)

        // Let the trailing-edge coalescer (0.15 s interval) fire once.
        try await Task.sleep(nanoseconds: 400_000_000)

        let volumeCommands = fake.commands(on: "system").filter { $0.hasPrefix("set volume output volume") }
        #expect(volumeCommands == ["set volume output volume 75"])
    }

    // MARK: - Actions

    /// TV declares `minActionInterval` 0.3 s; a second action inside that window
    /// is dropped rather than flooding the channel.
    @Test func actionIsRateLimitedByMinInterval() async {
        let fake = FakeSSHClient()
        fake.responder = { [sep] _, _ in .success("Show\(sep)   \(sep)true") }
        let controller = makeController(fake, platforms: [TVApp()])

        await controller.executeActionWithStatus(platform: TVApp(), action: .playPauseToggle)
        await controller.executeActionWithStatus(platform: TVApp(), action: .playPauseToggle)

        let tvCalls = fake.calls.filter { $0.channelKey == "tv" }
        #expect(tvCalls.count == 1)
        // The action script rode on the platform's own channel.
        #expect(tvCalls.first?.command.contains("playpause") == true)
    }

    // MARK: - Refresh strategy follows the transport's concurrency model

    /// Streaming serialises every app command on one channel, so the first
    /// refresh must fetch only the visible tab (+ volume) up front and defer the
    /// rest to the background prefetch — otherwise a bulk sweep queues behind
    /// itself and swipes feel slow.
    @Test func streamingRefreshesVisibleTabFirst() async {
        let fake = volumeAwareFake()
        fake.serializesAppCommands = true
        let controller = makeController(fake, platforms: [MusicApp(), TVApp()], enabled: ["music", "tv"])

        await controller.performInitialRefresh(visiblePlatformId: "music")
        controller.cleanup()   // cancel the fire-and-forget prefetch before it can run

        #expect(fake.commands(on: "system").count == 1)   // volume
        #expect(fake.commands(on: "music").count == 1)     // visible tab
        #expect(fake.commands(on: "tv").isEmpty)           // deferred to background
    }

    /// The legacy transport opens a channel per command (concurrent), so its
    /// first refresh sweeps every tab up front — the non-visible one included.
    @Test func legacyRefreshesEveryTabUpFront() async {
        let fake = volumeAwareFake()
        fake.serializesAppCommands = false
        let controller = makeController(fake, platforms: [MusicApp(), TVApp()], enabled: ["music", "tv"])

        await controller.performInitialRefresh(visiblePlatformId: "music")

        #expect(!fake.commands(on: "music").isEmpty)
        #expect(!fake.commands(on: "tv").isEmpty)
    }

    // MARK: - Foreground-only apps stay out of the background sweep

    /// IINA/mpv read status by foregrounding the Mac app, so a background bulk
    /// sweep must skip them — otherwise they'd pop to the front off-screen.
    @Test func bulkSweepExcludesForegroundOnlyApps() async {
        let fake = volumeAwareFake()
        let controller = makeController(fake, platforms: [MusicApp(), IINAApp()], enabled: ["music", "iina"])

        await controller.updateAllStates()

        #expect(!fake.commands(on: "music").isEmpty)
        #expect(fake.commands(on: "iina").isEmpty)
    }

    /// …but the tab that's actually on screen is refreshed even when it's a
    /// foreground-only app, since the pop-to-front is acceptable there.
    @Test func visibleForegroundOnlyAppIsRefreshed() async {
        let fake = volumeAwareFake()
        let controller = makeController(fake, platforms: [MusicApp(), IINAApp()], enabled: ["music", "iina"])

        await controller.updateAllStates(alwaysInclude: "iina")

        #expect(!fake.commands(on: "iina").isEmpty)
    }
}
