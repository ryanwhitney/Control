import Foundation

class PlatformRegistry: ObservableObject {
    @Published private(set) var platforms: [any MediaPlatform]
    @Published var enabledPlatforms: Set<String>
    
    init() {
        let allPlatforms: [any MediaPlatform] = [
            QuickTimePlatform(),
            VLCPlatform(),
            MusicPlatform(),
            SafariPlatform()
        ]
        self.platforms = allPlatforms
        
        let savedPlatforms = UserDefaults.standard.array(forKey: "EnabledPlatforms") as? [String]
        self.enabledPlatforms = Set(savedPlatforms ?? allPlatforms.map { $0.id })
    }
    
    func togglePlatform(_ id: String) {
        if enabledPlatforms.contains(id) {
            enabledPlatforms.remove(id)
        } else {
            enabledPlatforms.insert(id)
        }
        UserDefaults.standard.set(Array(enabledPlatforms), forKey: "EnabledPlatforms")
    }
    
    var activePlatforms: [any MediaPlatform] {
        platforms.filter { enabledPlatforms.contains($0.id) }
    }
} 
