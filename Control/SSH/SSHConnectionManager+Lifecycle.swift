import Foundation
import SwiftUI

// MARK: - App lifecycle
/// Scene-phase handling: on background, keep the process alive just long
/// enough to disconnect cleanly after 30 s; on foreground, cancel that.
extension SSHConnectionManager {

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        // Debounce duplicate calls (multiple views calling this simultaneously)
        let now = Date()
        if let last = lastScenePhaseChange,
           last.from == oldPhase && last.to == newPhase,
           now.timeIntervalSince(last.time) < 0.1 {
            return // Ignore duplicate call within 100ms
        }

        lastScenePhaseChange = (oldPhase, newPhase, now)
        connectionLog("Scene phase: \(oldPhase) -> \(newPhase)")

        switch newPhase {
        case .active:
            cancelBackgroundDisconnect()
            endBackgroundTask()
            // The heartbeat was paused on backgrounding; resume it for a live
            // connection. (When not connected, the view's own foreground path
            // re-drives a full connect, which starts it.)
            if connectionState == .connected && heartbeatTask == nil {
                startHeartbeat()
            }
        case .inactive:
            // No action needed, keep connection alive briefly
            break
        case .background:
            // Pause the heartbeat: a ping suspended mid-flight would fire its
            // stale watchdog on foreground and flash recovery — or drop a
            // healthy connection — before the real reply gets a chance.
            stopHeartbeat()
            startBackgroundDisconnectTimer()
        @unknown default:
            connectionLog("Unknown scene phase: \(newPhase)")
        }
    }

    private func startBackgroundDisconnectTimer() {
        cancelBackgroundDisconnect()

        // Keep the process alive long enough for the timer to fire
        startBackgroundTask()

        let disconnectTimer = DispatchWorkItem { [weak self] in
            connectionLog("⚰︎ App backgrounded for 30 seconds - disconnecting SSH")
            self?.disconnect()
            self?.endBackgroundTask()
        }

        backgroundDisconnectTimer = disconnectTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: disconnectTimer)
        connectionLog("⚰︎ Started 30-second background disconnect timer")
    }

    func cancelBackgroundDisconnect() {
        guard let timer = backgroundDisconnectTimer else { return }
        timer.cancel()
        backgroundDisconnectTimer = nil
        connectionLog("⚰︎ Cancelled background disconnect timer")
    }

    private func startBackgroundTask() {
        endBackgroundTask()

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSH Connection Cleanup") { [weak self] in
            // Background task is about to expire (system limit ~30-180 seconds)
            connectionLog("⚰︎ Background task expiring - disconnecting SSH")
            self?.client.disconnect()
            self?.disconnect()
            self?.endBackgroundTask()
        }

        if backgroundTask == .invalid {
            connectionLog("⚠️ Failed to start background task")
        } else {
            connectionLog("⚰︎ Started background task: \(backgroundTask)")
        }
    }

    func endBackgroundTask() {
        if backgroundTask != .invalid {
            connectionLog("⚰︎ Ending background task: \(backgroundTask)")
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
