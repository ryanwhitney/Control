import Foundation

class PlatformRegistry: ObservableObject {
    @Published private(set) var platforms: [any AppPlatform]
    @Published var enabledPlatforms: Set<String>
    
    static let allPlatforms: [any AppPlatform] = [
        QuickTimeApp(),
        VLCApp(),
        MusicApp(),
        TVApp(),
        SafariApp(),
        SpotifyApp(),
        ChromeApp()
    ]
    
    init(platforms: [any AppPlatform]? = nil) {
        let finalPlatforms = platforms ?? Self.allPlatforms
        self.platforms = finalPlatforms
        
        let savedPlatforms = UserDefaults.standard.array(forKey: "EnabledPlatforms") as? [String]
        self.enabledPlatforms = Set(savedPlatforms ?? finalPlatforms.map { $0.id })
    }
    
    var activePlatforms: [any AppPlatform] {
        platforms.filter { enabledPlatforms.contains($0.id) }
    }
    
    func togglePlatform(_ id: String) {
        if enabledPlatforms.contains(id) {
            enabledPlatforms.remove(id)
        } else {
            enabledPlatforms.insert(id)
        }
        UserDefaults.standard.set(Array(enabledPlatforms), forKey: "EnabledPlatforms")
    }
} 
