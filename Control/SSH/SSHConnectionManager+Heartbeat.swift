import Foundation

// MARK: - Heartbeat
/// Adaptive heartbeat: pings on a dedicated channel, speeding up right after
/// user activity and backing off when idle. Failures drive the
/// recovering → connected/lost transitions (and the one-shot streaming →
/// Compatibility auto-fallback).
extension SSHConnectionManager {

    func startHeartbeat() {
        stopHeartbeat()
        consecutiveHeartbeatFailures = 0
        currentHeartbeatInterval = minHeartbeatInterval
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.performHeartbeat() // immediate first ping
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.currentHeartbeatInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.performHeartbeat()
                // Fast pings right after activity; otherwise gradually back off.
                let recentlyActive = Date().timeIntervalSince(self.lastActivityAt) < 3
                self.currentHeartbeatInterval = recentlyActive
                    ? self.minHeartbeatInterval
                    : min(self.currentHeartbeatInterval + 1, self.maxHeartbeatInterval)
            }
        }
        connectionLog("♡ Heartbeat started (interval \(minHeartbeatInterval)s -> \(maxHeartbeatInterval)s)")

        recoveryDeadline = nil
    }

    func stopHeartbeat() {
        // Invalidate in-flight pings: their watchdogs/replies captured the old
        // generation and become no-ops (startHeartbeat calls this too, so a
        // restart also orphans the previous heartbeat's pings).
        heartbeatGeneration &+= 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connectionLog("⛔︎ Heartbeat stopped")
        recoveryDeadline = nil
    }

    private func performHeartbeat() async {
        let hbId = heartbeatCounter
        heartbeatCounter &+= 1
        let idString = ScriptTokens.heartbeat(hbId)
        let script = "return \"\(idString)\""
        let sendTime = Date()
        let generation = heartbeatGeneration
        var completed = false

        // Timeout watchdog
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let self, !completed, self.heartbeatGeneration == generation else { return }
            completed = true
            self.handleHeartbeatFailure(reason: "timeout waiting > \(heartbeatReplyTimeout)s for \(idString)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + heartbeatReplyTimeout, execute: timeoutTask)

        self.client.executeCommandOnDedicatedChannel("heartbeat", script, description: "heartbeat-\(idString)") { [weak self] result in
            // Hop to the MainActor before touching anything: this callback
            // arrives on a transport thread, while `completed` and the
            // handle… methods (which publish connectionState to SwiftUI) are
            // main-thread state. The watchdog above runs on the main queue, so
            // both writers of `completed` are now serialized.
            Task { @MainActor [weak self] in
                guard let self, !completed, self.heartbeatGeneration == generation else { return }
                completed = true
                timeoutTask.cancel()

                switch result {
                case .success(let output):
                    if output.contains(idString) {
                        self.handleHeartbeatSuccess(rtt: Date().timeIntervalSince(sendTime), id: idString)
                    } else {
                        let preview = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                        self.handleHeartbeatFailure(reason: "mismatched reply for \(idString): '\(preview)'")
                    }
                case .failure(let error):
                    self.handleHeartbeatFailure(reason: error.localizedDescription)
                }
            }
        }
    }

    private func handleHeartbeatSuccess(rtt: TimeInterval, id: String) {
        consecutiveHeartbeatFailures = 0
        // A real reply landed → this connection's transport works; a later drop is
        // a genuine disconnect, not a streaming-layer failure to auto-fall-back.
        heartbeatEverSucceeded = true
        // A stable heartbeat means any reconnect that got us here has settled;
        // clear the flap budget so future drops get a fresh set of retries.
        consecutiveReconnects = 0
        if connectionState == .recovering {
            connectionState = .connected
            connectionLog("✅ Recovery complete – connection restored (\(String(format: "%.0f", rtt*1000)) ms)")
        } else {
            connectionLog("♡ Heartbeat OK (\(id), \(String(format: "%.0f", rtt*1000)) ms)")
        }
        recoveryDeadline = nil
    }

    private func handleHeartbeatFailure(reason: String) {
        consecutiveHeartbeatFailures += 1
        connectionLog("⚠️ Heartbeat failure (#\(consecutiveHeartbeatFailures)): \(reason)")
        if consecutiveHeartbeatFailures == 1 {
            connectionState = .recovering
            recoveryDeadline = Date().addingTimeInterval(2)
            // Re-ping faster than the idle cadence so Compatibility (2s floor)
            // still gets more than one self-heal attempt inside the window;
            // 1s stays above LAN RTTs, so recovery pings don't overlap.
            currentHeartbeatInterval = min(minHeartbeatInterval, 1)
            connectionLog("🛠️ Entering recovering state – monitoring for 2s")
        } else {
            let shouldDrop = consecutiveHeartbeatFailures >= maxHeartbeatFailures && (recoveryDeadline.map { Date() >= $0 } ?? false)
            if shouldDrop {
                connectionLog("🚨 Recovery failed – treating as connection loss")
                // Allow the streaming→Compatibility auto-fallback here: this is the
                // precise "connected but never heard back" signal it keys off.
                handleConnectionLost(allowTransportFallback: true)
                stopHeartbeat()
            }
        }
    }
}
