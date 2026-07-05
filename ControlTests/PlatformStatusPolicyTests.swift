import Testing
@testable import Control

/// Guards which platforms are excluded from the global status sweep. IINA and
/// mpv read status via System Events (IINA must foreground to reach its menu
/// bar), so they must be checked only when their tab is visible; AppleScript
/// apps can be polled quietly in the background.
struct PlatformStatusPolicyTests {

    @Test func systemEventsAppsAreVisibleOnly() {
        #expect(IINAApp().checksStatusOnlyWhenVisible == true)
        #expect(MPVApp().checksStatusOnlyWhenVisible == true)
    }

    @Test func appleScriptAppsRefreshInBackground() {
        #expect(MusicApp().checksStatusOnlyWhenVisible == false)
        #expect(SpotifyApp().checksStatusOnlyWhenVisible == false)
        #expect(TVApp().checksStatusOnlyWhenVisible == false)
        #expect(SafariApp().checksStatusOnlyWhenVisible == false)
        #expect(VLCApp().checksStatusOnlyWhenVisible == false)
    }
}
