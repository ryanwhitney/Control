import UIKit

/// An SF Symbol a pad cell can show in place of its key's own cap. Curated
/// rather than free-form: symbol names aren't something users know.
struct PadIcon: Equatable, Identifiable {
    /// The SF Symbol name, which is also what's stored.
    let id: String
    /// Spoken by VoiceOver and accepted by Voice Control ("Tap Play").
    let name: String

    struct Section: Identifiable {
        let title: String
        let icons: [PadIcon]
        var id: String { title }
    }

    private static func section(_ title: String, _ icons: [(String, String)]) -> Section {
        Section(title: title, icons: icons.map { PadIcon(id: $0.0, name: $0.1) })
    }

    /// The icon picker's contents, in display order.
    static let sections: [Section] = [
        section("Media", [
            ("play.fill", "Play"), ("pause.fill", "Pause"), ("playpause.fill", "Play/Pause"),
            ("stop.fill", "Stop"), ("backward.fill", "Rewind"), ("forward.fill", "Fast Forward"),
            ("backward.end.fill", "Previous"), ("forward.end.fill", "Next"),
            ("gobackward.10", "Back 10 Seconds"), ("goforward.10", "Forward 10 Seconds"),
            ("repeat", "Repeat"), ("shuffle", "Shuffle"),
            ("speaker.wave.2.fill", "Volume"), ("speaker.slash.fill", "Mute"),
            ("captions.bubble.fill", "Captions"), ("pip.enter", "Picture in Picture"),
            ("arrow.up.left.and.arrow.down.right", "Full Screen"),
            ("arrow.down.right.and.arrow.up.left", "Exit Full Screen"),
        ]),
        section("Navigation", [
            ("chevron.left", "Back"), ("chevron.right", "Forward"),
            ("chevron.up", "Chevron Up"), ("chevron.down", "Chevron Down"),
            ("arrow.left", "Arrow Left"), ("arrow.right", "Arrow Right"),
            ("arrow.up", "Arrow Up"), ("arrow.down", "Arrow Down"),
            ("house.fill", "Home"), ("magnifyingglass", "Search"),
            ("arrow.clockwise", "Reload"), ("xmark", "Close"),
            ("checkmark", "Done"), ("list.bullet", "List"), ("sidebar.left", "Sidebar"),
        ]),
        section("Editing", [
            ("arrow.uturn.backward", "Undo"), ("arrow.uturn.forward", "Redo"),
            ("doc.on.doc", "Copy"), ("doc.on.clipboard", "Paste"), ("scissors", "Cut"),
            ("trash", "Delete"), ("square.and.arrow.down", "Save"),
            ("plus", "Plus"), ("minus", "Minus"),
            ("plus.magnifyingglass", "Zoom In"), ("minus.magnifyingglass", "Zoom Out"),
            ("textformat", "Text"),
        ]),
        section("Mac", [
            ("macwindow", "Window"), ("rectangle.stack", "Windows"),
            ("square.grid.2x2", "Grid"), ("menubar.rectangle", "Menu Bar"),
            ("dock.rectangle", "Dock"), ("keyboard", "Keyboard"), ("command", "Command"),
            ("printer.fill", "Print"), ("lock.fill", "Lock"),
            ("moon.fill", "Sleep"), ("sun.max.fill", "Brightness"),
        ]),
        section("Other", [
            ("star.fill", "Star"), ("heart.fill", "Heart"), ("bookmark.fill", "Bookmark"),
            ("flag.fill", "Flag"), ("bell.fill", "Bell"), ("gearshape.fill", "Settings"),
            ("mic.fill", "Microphone"), ("camera.fill", "Camera"), ("photo", "Photo"),
            ("music.note", "Music"), ("tv", "TV"), ("gamecontroller.fill", "Game"),
            ("hand.thumbsup.fill", "Thumbs Up"), ("eye.fill", "Eye"), ("bolt.fill", "Bolt"),
            ("info.circle", "Info"), ("questionmark.circle", "Help"),
        ]),
    ]

    static let all: [PadIcon] = sections.flatMap(\.icons)

    /// nil for a name this catalog doesn't list, such as one a newer version
    /// added. Such a cell still draws the symbol if this iOS has it.
    static func withID(_ id: String) -> PadIcon? {
        all.first { $0.id == id }
    }

    /// False for a symbol this iOS lacks, so the cell falls back to its key's
    /// cap rather than drawing blank.
    static func isDrawable(_ symbolName: String) -> Bool {
        UIImage(systemName: symbolName) != nil
    }
}
