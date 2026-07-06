//
//  ControlApp.swift
//  Control
//
//  Created by Ryan Whitney on 12/29/24.
//

import SwiftUI
import SwiftData
import Network

@main
struct VolumeControlApp: App {
    @StateObject private var networkPermissions = NetworkPermissions()
    @StateObject private var preferences = UserPreferences.shared

    var body: some Scene {
        WindowGroup {
            ConnectionsView()
                .onAppear {
                    networkPermissions.requestPermissions()
                }
                .tint(preferences.tintColorValue)
                .accentColor(preferences.tintColorValue)
                .preferredColorScheme(.dark)
        }
    }
}

/// Triggers the iOS local-network permission prompt. Starting a Bonjour
/// browser is what surfaces the system prompt.
class NetworkPermissions: ObservableObject {
    private let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: .tcp)

    func requestPermissions() {
        browser.start(queue: .main)

        // Add timeout to stop the permissions check
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak browser] in
            browser?.cancel()
        }
    }
}
