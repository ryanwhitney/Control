import Testing
import Foundation
@testable import Control

/// Drives `AppController` through an injected `FakeSSHClient`: the timing and
/// concurrency paths the static script-content tests can't reach. Hermetic, so
/// it belongs in the default suite.
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

        // Let the trailing-edge coalescer fire once.
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
        // Rode on the platform's own channel.
        #expect(tvCalls.first?.command.contains("playpause") == true)
    }

    /// The pad's send path carries no status read, so this is the only place a
    /// denied Automation permission can reach the readout.
    @Test func statuslessActionSurfacesPermissionError() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success("Not authorized to send Apple events") }
        let controller = makeController(fake, platforms: [KeyboardApp()])

        await controller.executeActionWithoutStatus(platform: KeyboardApp(), action: .key(.up))

        #expect(controller.states["keyboard"]?.title == "Permissions Required")
        #expect(controller.states["keyboard"]?.permissionKind == .automation)
    }

    /// The status read succeeds on Automation alone, so it has to report the
    /// missing assistive access itself — otherwise it overwrites the state a
    /// refused key press just set, and the readout flickers as the pad is used.
    @Test func accessibilitySentinelInStatusShowsPermissionsRequired() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success(ScriptTokens.accessibilityRequired) }
        let controller = makeController(fake, platforms: [KeyboardApp()])

        await controller.updateState(for: KeyboardApp(), force: true)

        #expect(controller.states["keyboard"]?.title == "Permissions Required")
        #expect(controller.states["keyboard"]?.permissionKind == .accessibility)
    }

    /// macOS refuses these with a message matching neither the Automation check
    /// nor a healthy send. Both transports hand it back as `.success` output, so
    /// the real message stands in for both.
    @Test func statuslessActionSurfacesAccessibilityError() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in
            .success("System Events got an error: osascript is not allowed to send keystrokes. (1002)")
        }
        let controller = makeController(fake, platforms: [KeyboardApp()])

        await controller.executeActionWithoutStatus(platform: KeyboardApp(), action: .key(.up))

        let state = controller.states["keyboard"]
        #expect(state?.title == "Permissions Required")
        // Drives the "How to fix this" button — neither state has a subtitle.
        #expect(state?.permissionKind == .accessibility)
    }

    /// The guard is dropped after a clean read and re-armed the moment a press is
    /// refused — otherwise a revoked grant would go unnoticed until reconnect,
    /// since the status read itself succeeds on Automation alone.
    @Test func assistiveGuardIsDroppedAfterCleanReadAndReArmedOnRefusal() async {
        let fake = FakeSSHClient()
        fake.responder = { [sep] _, _ in .success("Safari\(sep)\(sep)false") }
        let controller = makeController(fake, platforms: [KeyboardApp()])

        await controller.updateState(for: KeyboardApp(), force: true)
        await controller.updateState(for: KeyboardApp(), force: true)

        let scripts = fake.commands(on: "keyboard")
        #expect(scripts.count == 2)
        #expect(scripts[0].contains("UI elements enabled"))
        #expect(!scripts[1].contains("UI elements enabled"))

        fake.responder = { _, _ in
            .success("System Events got an error: osascript is not allowed to send keystrokes. (1002)")
        }
        await controller.executeActionWithoutStatus(platform: KeyboardApp(), action: .key(.up))
        fake.responder = { [sep] _, _ in .success("Safari\(sep)\(sep)false") }
        await controller.updateState(for: KeyboardApp(), force: true)

        #expect(fake.commands(on: "keyboard").last?.contains("UI elements enabled") == true)
    }

    /// IINA and mpv UI-script their status read, so the poll itself is refused
    /// and there's no sentinel to match. Without this it parses as a script
    /// error, and since the poll runs on every tab visit it overwrites the state
    /// a refused press just set.
    @Test func statusPollSurfacesAccessibilityError() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in
            .success("System Events got an error: osascript is not allowed assistive access. (-1719)")
        }
        let controller = makeController(fake, platforms: [MPVApp()])

        await controller.updateState(for: MPVApp(), force: true)

        let state = controller.states["mpv"]
        #expect(state?.title == "Permissions Required")
        #expect(state?.permissionKind == .accessibility)
    }

    /// IINA, mpv and TV send their keys through the status-bundling path, so it
    /// needs the same check. The refused key aborts the script, so the error can
    /// arrive after the action's own output with no status line behind it —
    /// matching only the first line would miss it.
    @Test func withStatusActionSurfacesAccessibilityError() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in
            .success("\nSystem Events got an error: osascript is not allowed to send keystrokes. (1002)")
        }
        let controller = makeController(fake, platforms: [MPVApp()])

        await controller.executeActionWithStatus(platform: MPVApp(), action: .playPauseToggle)

        let state = controller.states["mpv"]
        #expect(state?.title == "Permissions Required")
        #expect(state?.permissionKind == .accessibility)
    }

    /// The rate limit applies to the status-less path too, so a platform that
    /// declares one can't be flooded by routing around `executeActionWithStatus`.
    @Test func statuslessActionIsRateLimitedByMinInterval() async {
        let fake = FakeSSHClient()
        fake.responder = { _, _ in .success("") }
        let controller = makeController(fake, platforms: [TVApp()])

        await controller.executeActionWithoutStatus(platform: TVApp(), action: .key(.up))
        await controller.executeActionWithoutStatus(platform: TVApp(), action: .key(.up))

        #expect(fake.calls.filter { $0.channelKey == "tv" }.count == 1)
    }

    // MARK: - Refresh strategy follows the transport's concurrency model

    /// Streaming serialises every app command, so a bulk first refresh would
    /// queue behind itself and make swipes feel slow.
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

    /// Legacy opens a channel per command, so it can sweep every tab up front.
    @Test func legacyRefreshesEveryTabUpFront() async {
        let fake = volumeAwareFake()
        fake.serializesAppCommands = false
        let controller = makeController(fake, platforms: [MusicApp(), TVApp()], enabled: ["music", "tv"])

        await controller.performInitialRefresh(visiblePlatformId: "music")

        #expect(!fake.commands(on: "music").isEmpty)
        #expect(!fake.commands(on: "tv").isEmpty)
    }

    // MARK: - Foreground-only apps stay out of the background sweep

    /// These read status by foregrounding the Mac app, so a background sweep
    /// would pop them to the front off-screen.
    @Test func bulkSweepExcludesForegroundOnlyApps() async {
        let fake = volumeAwareFake()
        let controller = makeController(fake, platforms: [MusicApp(), IINAApp()], enabled: ["music", "iina"])

        await controller.updateAllStates()

        #expect(!fake.commands(on: "music").isEmpty)
        #expect(fake.commands(on: "iina").isEmpty)
    }

    /// …but the tab on screen is refreshed anyway: popping to the front is fine
    /// when the user is looking at it.
    @Test func visibleForegroundOnlyAppIsRefreshed() async {
        let fake = volumeAwareFake()
        let controller = makeController(fake, platforms: [MusicApp(), IINAApp()], enabled: ["music", "iina"])

        await controller.updateAllStates(alwaysInclude: "iina")

        #expect(!fake.commands(on: "iina").isEmpty)
    }
}
