//
//  VolumeControlApp.swift
//  VolumeControl
//
//  Created by Ryan Whitney on 12/29/24.
//

import SwiftUI
import SwiftData
import Network

@main
struct VolumeControlApp: App {
    @StateObject private var networkPermissions = NetworkPermissions()
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ComputerListView()
                .onAppear {
                    networkPermissions.requestPermissions()
                }
                .tint(Color.green)
        }
        .modelContainer(sharedModelContainer)
    }
}

// Class to handle network permissions
class NetworkPermissions: ObservableObject {
    private let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: .tcp)
    
    func requestPermissions() {
        // Start and immediately stop the browser to trigger the permission request
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                self.browser.cancel()
            default:
                break
            }
        }
        browser.start(queue: .main)
    }
}
