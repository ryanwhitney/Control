import Foundation

class PlatformRegistry: ObservableObject {
    @Published private(set) var platforms: [any AppPlatform]
    @Published var enabledPlatforms: Set<String>
    @Published var enabledExperimentalPlatforms: Set<String>
    
    static let allPlatforms: [any AppPlatform] = [
        QuickTimeApp(),
        TVApp(),
        MusicApp(),
        VLCApp(),
        IINAApp(),
        SpotifyApp(),
        SafariApp(),
//        ChromeApp()
    ]
    
    init(platforms: [any AppPlatform]? = nil) {
        let finalPlatforms = platforms ?? Self.allPlatforms
        self.platforms = finalPlatforms
        
        let savedPlatforms = UserDefaults.standard.array(forKey: "EnabledPlatforms") as? [String]
        let savedExperimentalPlatforms = UserDefaults.standard.array(forKey: "EnabledExperimentalPlatforms") as? [String]
        
        self.enabledPlatforms = Set(savedPlatforms ?? finalPlatforms.filter { !$0.experimental && $0.defaultEnabled }.map { $0.id })
        self.enabledExperimentalPlatforms = Set(savedExperimentalPlatforms ?? [])
    }
    
    var activePlatforms: [any AppPlatform] {
        platforms.filter { platform in
            return enabledPlatforms.contains(platform.id)
        }
    }
    
    var nonExperimentalPlatforms: [any AppPlatform] {
        platforms.filter { !$0.experimental }
    }
    
    var experimentalPlatforms: [any AppPlatform] {
        platforms.filter { $0.experimental }
    }
    
    func togglePlatform(_ id: String) {
        if enabledPlatforms.contains(id) {
            enabledPlatforms.remove(id)
        } else {
            enabledPlatforms.insert(id)
        }
        UserDefaults.standard.set(Array(enabledPlatforms), forKey: "EnabledPlatforms")
    }
    
    func toggleExperimentalPlatform(_ id: String) {
        if enabledExperimentalPlatforms.contains(id) {
            enabledExperimentalPlatforms.remove(id)
        } else {
            enabledExperimentalPlatforms.insert(id)
        }
        UserDefaults.standard.set(Array(enabledExperimentalPlatforms), forKey: "EnabledExperimentalPlatforms")
    }
} 
