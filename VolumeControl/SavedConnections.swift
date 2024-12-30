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
        
        init(hostname: String, name: String? = nil, username: String? = nil) {
            self.id = UUID()
            self.hostname = hostname
            self.name = name
            self.username = username
            self.lastUsed = Date()
        }
    }
    
    init() {
        load()
    }
    
    func add(hostname: String, name: String? = nil, username: String? = nil, password: String? = nil) {
        // Don't add if already exists
        guard !items.contains(where: { $0.hostname == hostname }) else { return }
        
        let connection = SavedConnection(hostname: hostname, name: name, username: username)
        items.append(connection)
        save()
        
        // Save password to keychain if provided
        if let password = password {
            savePassword(password, for: hostname)
        }
    }
    
    func updateLastUsername(for hostname: String, name: String? = nil, username: String, password: String? = nil) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].username = username
            if let name = name {
                items[index].name = name
            }
            save()
            
            if let password = password {
                savePassword(password, for: hostname)
            }
        } else {
            add(hostname: hostname, name: name, username: username, password: password)
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
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
} 