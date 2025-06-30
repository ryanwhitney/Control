import SwiftUI

struct SetupFlowView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let isReconfiguration: Bool
    let onComplete: () -> Void
    
    @EnvironmentObject private var savedConnections: SavedConnections
    @State private var currentStep: SetupStep = .chooseApps
    @State private var selectedPlatforms: Set<String> = []
    
    enum SetupStep {
        case chooseApps
        case permissions
    }
    
    var body: some View {
        Group {
            switch currentStep {
            case .chooseApps:
                // Get the current enabled platforms for both display and comparison
                let currentEnabledPlatforms = savedConnections.enabledPlatforms(host)
                
                ChooseAppsView(
                    host: host,
                    displayName: displayName,
                    username: username,
                    password: password,
                    initialSelection: isReconfiguration ? currentEnabledPlatforms : nil,
                    onComplete: { platforms in
                        selectedPlatforms = platforms
                        
                        // Determine if we need to go through permissions BEFORE updating saved state
                        let shouldSkipPermissions: Bool
                        
                        if platforms.isEmpty {
                            // No apps selected - always skip permissions
                            shouldSkipPermissions = true
                        } else if !isReconfiguration {
                            // First-time setup - always go through permissions
                            shouldSkipPermissions = false
                        } else {
                            // Reconfiguration - only go through permissions if enabling new apps
                            // Use the captured platforms for comparison, not the state variable
                            let hasNewApps = !platforms.isSubset(of: currentEnabledPlatforms)
                            shouldSkipPermissions = !hasNewApps
                            
                            viewLog("SetupFlowView: Reconfiguration analysis", view: "SetupFlowView")
                            viewLog("  Initial platforms: \(currentEnabledPlatforms)", view: "SetupFlowView")
                            viewLog("  Selected platforms: \(platforms)", view: "SetupFlowView")
                            viewLog("  Has new apps: \(hasNewApps)", view: "SetupFlowView")
                            viewLog("  Will skip permissions: \(shouldSkipPermissions)", view: "SetupFlowView")
                        }
                        
                        // Now update the saved state AFTER our comparison
                        savedConnections.updateEnabledPlatforms(host, platforms: platforms)
                        
                        if shouldSkipPermissions {
                            if !isReconfiguration {
                                savedConnections.markAsConnected(host)
                            }
                            // Exit the setup flow - return to original ControlView
                            onComplete()
                        } else {
                            currentStep = .permissions
                        }
                    }
                )
                
            case .permissions:
                PermissionsView(
                    host: host,
                    displayName: displayName,
                    username: username,
                    password: password,
                    enabledPlatforms: selectedPlatforms,
                    onComplete: {
                        if !isReconfiguration {
                            savedConnections.markAsConnected(host)
                        }
                        // Exit the setup flow - return to original ControlView
                        onComplete()
                    }
                )
            }
        }
        .navigationBarBackButtonHidden(currentStep == .permissions)
        .toolbar {
            if currentStep == .permissions {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        currentStep = .chooseApps
                    }
                }
            }
        }
        .onAppear {
            // Always reset to the beginning when the flow appears
            currentStep = .chooseApps
            selectedPlatforms = [] // Reset selected platforms from previous runs
            
            if isReconfiguration {
                let currentPlatforms = savedConnections.enabledPlatforms(host)
                viewLog("SetupFlowView: Starting reconfiguration with platforms: \(currentPlatforms)", view: "SetupFlowView")
            } else {
                viewLog("SetupFlowView: Starting first-time setup", view: "SetupFlowView")
            }
        }
    }
} 