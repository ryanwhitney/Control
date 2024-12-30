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
    
    var body: some Scene {
        WindowGroup {
            ComputerListView()
                .onAppear {
                    networkPermissions.requestPermissions()
                }
                .tint(.green)
        }
    }
}

// Class to handle network permissions
class NetworkPermissions: ObservableObject {
    @Published var isAuthorized = false
    private let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: .tcp)
    
    func requestPermissions() {
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isAuthorized = true
                }
            case .failed:
                DispatchQueue.main.async {
                    self.isAuthorized = false
                }
            default:
                break
            }
        }
        browser.start(queue: .main)
        
        // Add timeout to stop the permissions check
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak browser] in
            browser?.cancel()
        }
    }
}
