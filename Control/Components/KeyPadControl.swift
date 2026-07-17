import SwiftUI

/// The generic key pad: a D-pad with space at its centre, and escape/return at
/// the top corners. Every key is a plain `key code` sent to whatever app is
/// frontmost on the Mac (see `KeyboardApp`).
///
/// Deliberately not built from `supportedActions` like the transport row: the
/// arrangement here is positional, and a flat list can't say which key belongs
/// in the middle.
struct KeyPadControl: View {
    let platform: any AppPlatform
    /// Phone landscape, where the four-row portrait arrangement doesn't fit —
    /// escape/return move out to the sides instead of sitting above.
    let isCompact: Bool
    @EnvironmentObject var controller: AppController

    private let spacing: CGFloat = 8

    var body: some View {
        if isCompact {
            HStack(spacing: 24) {
                keyButton(.escape)
                directionCluster
                keyButton(.return)
            }
        } else {
            // A grid so escape/return land in the same outer columns as
            // left/right — the corners — without hardcoding the button pitch.
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    keyButton(.escape)
                    emptyCell
                    keyButton(.return)
                }
                GridRow {
                    emptyCell
                    keyButton(.up)
                    emptyCell
                }
                GridRow {
                    keyButton(.left)
                    keyButton(.space)
                    keyButton(.right)
                }
                GridRow {
                    emptyCell
                    keyButton(.down)
                    emptyCell
                }
            }
        }
    }

    private var directionCluster: some View {
        VStack(spacing: spacing) {
            keyButton(.up)
            HStack(spacing: spacing) {
                keyButton(.left)
                keyButton(.space)
                keyButton(.right)
            }
            keyButton(.down)
        }
    }

    private var emptyCell: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }

    private func keyButton(_ key: RemoteKey) -> some View {
        Button {
            Task {
                await controller.executeActionWithStatus(platform: platform, action: .key(key))
            }
        } label: {
            // Sized by IconButtonStyle's font rather than a resizable frame (the
            // transport row's approach): these glyphs don't share an aspect
            // ratio — the arrows are square, space/escape/return are wide and
            // short — so a uniform box would render space as a sliver. Font
            // sizing gives them Apple's optical balance instead.
            Image(systemName: key.icon)
                .accessibilityLabel(key.label)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityInputLabels(AppAction.key(key).inputLabels)
    }
}

#Preview {
    KeyPadControl(platform: KeyboardApp(), isCompact: false)
        .environmentObject(
            AppController(sshClient: SSHClient(), platformRegistry: PlatformRegistry())
        )
        .preferredColorScheme(.dark)
}
