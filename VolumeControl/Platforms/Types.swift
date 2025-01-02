import Foundation
import SwiftUI

enum AppAction: Identifiable {
    case skipForward(Int)
    case skipBackward(Int)
    case previousTrack
    case nextTrack
    case playPauseToggle
    case playPauseStatic(Bool)
    case setVolume(Float)
    
    var id: String {
        switch self {
        case .skipForward(let seconds): return "forward\(seconds)"
        case .skipBackward(let seconds): return "backward\(seconds)"
        case .previousTrack: return "previousTrack"
        case .nextTrack: return "nextTrack"
        case .playPauseToggle: return "playPauseToggle"
        case .playPauseStatic: return "playPauseStatic"
        case .setVolume(let level): return "volume\(level)"
        }
    }
    
    var icon: String {
        switch self {
        case .skipForward(let seconds):
            return "\(seconds).arrow.trianglehead.clockwise"
        case .skipBackward(let seconds):
            return "\(seconds).arrow.trianglehead.counterclockwise"
        case .previousTrack:
            return "arrowtriangle.backward.fill"
        case .nextTrack:
            return "arrowtriangle.forward.fill"
        case .playPauseToggle:
            return "playpause.fill"
        case .playPauseStatic(let isPlaying):
            return isPlaying ? "pause.fill" : "play.fill"
        case .setVolume:
            return "speaker.wave.3.fill"
        }
    }
    
    var label: String {
        switch self {
        case .skipForward(let seconds):
            return "Forward \(seconds) seconds"
        case .skipBackward(let seconds):
            return "Back \(seconds) seconds"
        case .previousTrack:
            return "Previous track"
        case .nextTrack:
            return "Next track"
        case .playPauseToggle:
            return "Play/Pause"
        case .playPauseStatic:
            return "Play/Pause"
        case .setVolume:
            return "Volume"
        }
    }
}

struct AppState: Equatable {
    var title: String
    var subtitle: String?
    var isPlaying: Bool?
    var error: String?
}

protocol AppPlatform: Identifiable {
    var id: String { get }
    var name: String { get }
    var supportedActions: [AppAction] { get }
    
    func fetchState() -> String
    func executeAction(_ action: AppAction) -> String
    func parseState(_ output: String) -> AppState
} 
