import SwiftUI

// MARK: - Setup Flow Context
struct SetupFlowContext {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let isReconfiguration: Bool
}

// MARK: - Setup Flow Navigation
struct SetupFlowNavigationView: View {
    let context: SetupFlowContext
    let onComplete: () -> Void
    
    @EnvironmentObject private var savedConnections: SavedConnections
    @State private var originalEnabledPlatforms: Set<String> = [] // For comparison logic only
    @State private var temporarySelectedPlatforms: Set<String>? = nil // Intermediate state during flow
    @State private var permissionsContext: PermissionsNavigationContext?
    
    private var chooseAppsInitialSelection: Set<String>? {
        // During an active flow.
        if let temporary = temporarySelectedPlatforms {
            viewLog("SetupFlow: Using temporary selection: \(temporary)", view: "SetupFlowNavigationView")
            return temporary
        }
        
        // Reconfiguring an existing connection.
        if context.isReconfiguration {
            let saved = savedConnections.enabledPlatforms(context.host)
            viewLog("SetupFlow: Using saved platforms: \(saved)", view: "SetupFlowNavigationView")
            return saved
        }
        
        // New setup.
        viewLog("SetupFlow: Using default platforms (nil - will be resolved by ChooseAppsView)", view: "SetupFlowNavigationView")
        return nil
    }
    
    var body: some View {
        ChooseAppsView(
            host: context.host,
            displayName: context.displayName,
            username: context.username,
            password: context.password,
            initialSelection: chooseAppsInitialSelection,
            onComplete: { selectedPlatforms in
                handlePlatformSelection(selectedPlatforms)
            }
        )
        .navigationDestination(item: $permissionsContext) { permContext in
            PermissionsView(
                host: permContext.host,
                displayName: permContext.displayName,
                username: permContext.username,
                password: permContext.password,
                enabledPlatforms: permContext.platformsToCheck,
                onComplete: {
                    // The full selection, not just the checked subset.
                    savedConnections.updateEnabledPlatforms(permContext.host, platforms: permContext.enabledPlatforms)
                    if !context.isReconfiguration {
                        savedConnections.markAsConnected(permContext.host)
                    }
                    
                    temporarySelectedPlatforms = nil
                    
                    onComplete()
                }
            )
        }
        .navigationBarBackButtonHidden(false)
        .onAppear {
            // For comparison only.
            originalEnabledPlatforms = savedConnections.enabledPlatforms(context.host)
        }
    }
    
    private func handlePlatformSelection(_ selectedPlatforms: Set<String>) {
        // The source of truth during the flow.
        temporarySelectedPlatforms = selectedPlatforms

        // Re-checking an already-granted app would needlessly re-activate it on
        // the Mac. First-time setup has an empty baseline, so all count as new.
        let newApps = selectedPlatforms.subtracting(originalEnabledPlatforms)

        if newApps.isEmpty {
            // Nothing new to grant.
            savedConnections.updateEnabledPlatforms(context.host, platforms: selectedPlatforms)
            if !context.isReconfiguration {
                savedConnections.markAsConnected(context.host)
            }

            temporarySelectedPlatforms = nil

            onComplete()
        } else {
            permissionsContext = PermissionsNavigationContext(
                host: context.host,
                displayName: context.displayName,
                username: context.username,
                password: context.password,
                enabledPlatforms: selectedPlatforms,
                platformsToCheck: newApps
            )
        }
    }
}

// MARK: - Permissions Navigation Context
struct PermissionsNavigationContext: Identifiable, Hashable {
    let id = UUID()
    let host: String
    let displayName: String
    let username: String
    let password: String
    /// The full selection to persist on completion.
    let enabledPlatforms: Set<String>
    /// The subset actually verified: the apps newly added in this pass.
    let platformsToCheck: Set<String>
}

// MARK: - SetupFlowView
struct SetupFlowView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let isReconfiguration: Bool
    let onComplete: () -> Void
    
    var body: some View {
        SetupFlowNavigationView(
            context: SetupFlowContext(
                host: host,
                displayName: displayName,
                username: username,
                password: password,
                isReconfiguration: isReconfiguration
            ),
            onComplete: onComplete
        )
    }
} 
