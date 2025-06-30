import Foundation
import Security

class SavedConnections: ObservableObject {
    @Published private(set) var items: [SavedConnection] = []
    private let saveKey = "SavedConnections"
    
    struct SavedConnection: Codable, Identifiable {
        let id: UUID
        let hostname: String
        var name: String?
        var username: String?
        let lastUsed: Date
        var hasConnectedBefore: Bool
        var enabledPlatforms: Set<String>
        var lastViewedPlatform: String?
        var saveCredentialsPreference: Bool?  // nil = legacy
        
        init(hostname: String, name: String? = nil, username: String? = nil) {
            self.id = UUID()
            self.hostname = hostname
            self.name = name
            self.username = username
            self.lastUsed = Date()
            self.hasConnectedBefore = false
            self.enabledPlatforms = []
            self.lastViewedPlatform = nil
            self.saveCredentialsPreference = nil
        }
    }
    
    init() {
        load()
    }
    
    func add(hostname: String, name: String? = nil, username: String? = nil, password: String? = nil, saveCredentials: Bool) {
        // Update existing connection if it exists
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].username = username
            if let name = name {
                items[index].name = name
            }
            items[index].saveCredentialsPreference = saveCredentials
            save()
        } else {
            // Create new connection
            var connection = SavedConnection(hostname: hostname, name: name, username: username)
            connection.saveCredentialsPreference = saveCredentials
            items.append(connection)
            save()
        }
        
        // Save or remove password based on preference
        if saveCredentials, let password = password {
            savePassword(password, for: hostname)
        } else if !saveCredentials {
            // Remove password if user chose not to save credentials
            removePassword(for: hostname)
        }
    }
    
    func updateLastUsername(for hostname: String, name: String? = nil, username: String, password: String? = nil, saveCredentials: Bool) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].username = username
            if let name = name {
                items[index].name = name
            }
            items[index].saveCredentialsPreference = saveCredentials
            save()
            
            // Save or remove password based on preference
            if saveCredentials, let password = password {
                savePassword(password, for: hostname)
            } else if !saveCredentials {
                removePassword(for: hostname)
            }
        } else {
            add(hostname: hostname, name: name, username: username, password: password, saveCredentials: saveCredentials)
        }
    }
    
    func lastUsername(for hostname: String) -> String? {
        return items.first(where: { $0.hostname == hostname })?.username
    }
    
    func password(for hostname: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }
        
        return password
    }
    
    private func savePassword(_ password: String, for hostname: String) {
        // First try to delete any existing password
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Now save the new password
        guard let passwordData = password.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Failed to save password to keychain: \(status)")
        }
    }
    
    private func removePassword(for hostname: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
    
    func getSaveCredentialsPreference(for hostname: String) -> Bool {
        // Return the user's preference, defaulting to false for legacy connections, true for new ones
        if let connection = items.first(where: { $0.hostname == hostname }) {
            return connection.saveCredentialsPreference ?? false  // Legacy connections default to false (safer)
        } else {
            return true  // New connections default to true
        }
    }
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return
        }
        items = decoded
    }
    
    private func save() {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(encoded, forKey: saveKey)
    }
    
    func remove(hostname: String) {
        // Remove from saved items
        items.removeAll { $0.hostname == hostname }
        save()
        
        // Remove password from keychain
        removePassword(for: hostname)
    }
    
    func markAsConnected(_ hostname: String) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].hasConnectedBefore = true
            save()
        }
    }
    
    func updateEnabledPlatforms(_ hostname: String, platforms: Set<String>) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].enabledPlatforms = platforms
            save()
        }
    }
    
    func hasConnectedBefore(_ hostname: String) -> Bool {
        return items.first(where: { $0.hostname == hostname })?.hasConnectedBefore ?? false
    }
    
    func enabledPlatforms(_ hostname: String) -> Set<String> {
        return items.first(where: { $0.hostname == hostname })?.enabledPlatforms ?? []
    }
    
    func updateLastViewedPlatform(_ hostname: String, platform: String) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].lastViewedPlatform = platform
            save()
        }
    }
    
    func lastViewedPlatform(_ hostname: String) -> String? {
        return items.first(where: { $0.hostname == hostname })?.lastViewedPlatform
    }
}
