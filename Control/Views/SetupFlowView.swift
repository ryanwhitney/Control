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
    
    // Clear priority system for initial selection
    private var chooseAppsInitialSelection: Set<String>? {
        // Priority 1: Temporary selection (during active flow)
        if let temporary = temporarySelectedPlatforms {
            viewLog("SetupFlow: Using temporary selection: \(temporary)", view: "SetupFlowNavigationView")
            return temporary
        }
        
        // Priority 2: Saved platforms (for reconfiguration)
        if context.isReconfiguration {
            let saved = savedConnections.enabledPlatforms(context.host)
            viewLog("SetupFlow: Using saved platforms: \(saved)", view: "SetupFlowNavigationView")
            return saved
        }
        
        // Priority 3: Default platforms (for new setup)
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
                    // Save the full selection (not just the checked subset) and finish
                    savedConnections.updateEnabledPlatforms(permContext.host, platforms: permContext.enabledPlatforms)
                    if !context.isReconfiguration {
                        savedConnections.markAsConnected(permContext.host)
                    }
                    
                    // Clear temporary state since we're done
                    temporarySelectedPlatforms = nil
                    
                    onComplete()
                }
            )
        }
        .navigationBarBackButtonHidden(false)
        .onAppear {
            // Capture the original enabled platforms at the start (for comparison logic only)
            originalEnabledPlatforms = savedConnections.enabledPlatforms(context.host)
        }
    }
    
    private func handlePlatformSelection(_ selectedPlatforms: Set<String>) {
        // ALWAYS update temporary state - this is our source of truth during the flow
        temporarySelectedPlatforms = selectedPlatforms

        // Only apps newly added in this pass need a permission check; anything
        // already set up on this connection was granted before, and re-checking it
        // would needlessly re-activate that app on the Mac. First-time setup has an
        // empty baseline, so every selected app counts as new.
        let newApps = selectedPlatforms.subtracting(originalEnabledPlatforms)

        if newApps.isEmpty {
            // Nothing new to grant - save the selection and complete the flow.
            savedConnections.updateEnabledPlatforms(context.host, platforms: selectedPlatforms)
            if !context.isReconfiguration {
                savedConnections.markAsConnected(context.host)
            }

            // Clear temporary state since we're done
            temporarySelectedPlatforms = nil

            onComplete()
        } else {
            // Navigate to permissions, checking only the newly added apps.
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
    /// The subset actually verified on the permissions screen — the apps newly
    /// added in this pass. Previously-granted apps are saved but not re-checked.
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
