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
                enabledPlatforms: permContext.enabledPlatforms,
                onComplete: {
                    // Save the final selection and complete the flow
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
        
        let shouldSkipPermissions: Bool
        
        if selectedPlatforms.isEmpty {
            // No apps selected - skip permissions and save empty selection
            shouldSkipPermissions = true
        } else if !context.isReconfiguration {
            // First-time setup - always go through permissions
            shouldSkipPermissions = false
        } else {
            // Reconfiguration - only go through permissions if enabling new apps
            // Compare against ORIGINAL platforms (captured at start), not temporary state
            let hasNewApps = !selectedPlatforms.isSubset(of: originalEnabledPlatforms)
            shouldSkipPermissions = !hasNewApps
            
        }
        
        if shouldSkipPermissions {
            // Save the selection and complete the flow
            savedConnections.updateEnabledPlatforms(context.host, platforms: selectedPlatforms)
            if !context.isReconfiguration {
                savedConnections.markAsConnected(context.host)
            }
            
            // Clear temporary state since we're done
            temporarySelectedPlatforms = nil
            
            onComplete()
        } else {
            // Navigate to permissions by setting the context
            permissionsContext = PermissionsNavigationContext(
                host: context.host,
                displayName: context.displayName,
                username: context.username,
                password: context.password,
                enabledPlatforms: selectedPlatforms
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
    let enabledPlatforms: Set<String>
}

// MARK: - Legacy SetupFlowView (for compatibility)
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
