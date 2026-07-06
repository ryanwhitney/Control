import Testing
import Foundation
@testable import Control

/// Live tests that drive the real `AppController` over the real SSH transport —
/// the full production stack minus SwiftUI. The hermetic `AppControllerTests`
/// prove the orchestration logic against a `FakeSSHClient`; these prove the same
/// logic against real network latency and a real Mac: the volume coalescer's
/// trailing send actually lands, an initial refresh actually populates published
/// state, an action actually flips what the UI would render.
///
/// Declared as an extension of `LiveIntegrationTests` so the suite's traits
/// (`.serialized`, the `VC_LIVE` gate, `.tags(.live)`, the time limit) apply —
/// these tests mutate the same one Mac as the rest of the live suite.
extension LiveIntegrationTests {

    /// A controller wired to the live connection, with just the platforms a test
    /// needs enabled (pinned, ignoring persisted defaults).
    @MainActor
    private func makeLiveController(_ env: LiveEnvironment, platforms: [any AppPlatform]) -> AppController {
        let registry = PlatformRegistry(platforms: platforms)
        registry.enabledPlatforms = Set(platforms.map { $0.id })
        return AppController(sshClient: env.client, platformRegistry: registry)
    }

    /// `performInitialRefresh` — the exact call the UI makes after connecting —
    /// must populate published state over a real connection on both transports:
    /// a real volume arrives and the visible tab's "Loading..." placeholder is
    /// replaced by a real parse (running, not running, or permissions — anything
    /// but an error), regardless of what the Mac happens to be running.
    @MainActor
    @Test(arguments: LiveEnvironment.Transport.allCases)
    func controllerInitialRefreshPopulatesState(_ transport: LiveEnvironment.Transport) async throws {
        let env = try await LivePool.shared.env(transport)
        let controller = makeLiveController(env, platforms: [MusicApp()])

        await controller.performInitialRefresh(visiblePlatformId: "music")
        controller.cleanup()   // cancel the fire-and-forget background prefetch

        #expect(controller.hasCompletedInitialUpdate)
        #expect(controller.currentVolume != nil, "no volume arrived over \(transport)")
        let state = try #require(controller.states["music"])
        #expect(state.title != "Loading...", "visible tab was never refreshed over \(transport)")
        #expect(state.error == nil, "status errored over \(transport): \(state.error ?? "")")
    }

    /// Rapid `setVolume` calls — a slider drag — must coalesce to the *latest*
    /// value and that value must actually land on the Mac. The hermetic twin
    /// asserts the coalescing; this asserts the whole path through the trailing
    /// send, the real channel, and the Mac's mixer. Restores when done.
    @MainActor
    @Test func controllerVolumeCoalescesToTheMac() async throws {
        let env = try await LivePool.shared.env()
        let original = try await env.run("output volume of (get volume settings)")
        let originalInt = try #require(Int(original), "volume output not numeric: '\(original)'")

        // 0.25/0.75 are exact in binary, so Int(target * 100) can't truncate.
        let target: Float = originalInt >= 50 ? 0.25 : 0.75
        let controller = makeLiveController(env, platforms: [MusicApp()])
        controller.setVolume(0.5)
        controller.setVolume(target)

        // Poll until the coalescer's trailing send lands (well under a second;
        // the suite time limit backstops a genuine hang).
        var reported: Int?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            reported = Int(try await env.run("output volume of (get volume settings)"))
            if reported == Int(target * 100) { break }
        }
        #expect(reported == Int(target * 100),
                "coalesced volume never reached the Mac: last read \(String(describing: reported))")

        controller.cleanup()
        _ = try await env.run("set volume output volume \(originalInt)")   // restore
    }

    /// A play/pause sent through `executeActionWithStatus` must update the
    /// *published* state the UI renders — action script, settling wrapper,
    /// parse, and `states` publication, all against the real app. Restores.
    @MainActor
    @Test func controllerPlayPauseUpdatesPublishedState() async throws {
        let env = try await LivePool.shared.env()
        let music = MusicApp()
        guard let before = try await env.loadedState(music) else {
            return liveSkip("controller play/pause", "Music is not running or has nothing loaded — run Scripts/live-setup.sh")
        }
        let wasPlaying = before.isPlaying == true
        let controller = makeLiveController(env, platforms: [music])

        await controller.executeActionWithStatus(platform: music, action: .playPauseToggle)
        #expect(controller.states["music"]?.isPlaying == !wasPlaying,
                "published state did not flip \(wasPlaying) → \(String(describing: controller.states["music"]?.isPlaying))")

        await controller.executeActionWithStatus(platform: music, action: .playPauseToggle)   // restore
        controller.cleanup()
    }
}
