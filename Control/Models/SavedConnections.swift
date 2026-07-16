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
        var hostKeyFingerprint: String?  // most-recently-observed key, for display; nil = never pinned
        var hostKeyType: String?  // paired with hostKeyFingerprint
        var hostKeyFingerprints: [String]?  // every key the user has accepted for this host (known_hosts-style set)

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
            self.hostKeyFingerprint = nil
            self.hostKeyType = nil
            self.hostKeyFingerprints = nil
        }
    }
    
    init() {
        load()
    }
    
    func add(hostname: String, name: String? = nil, username: String? = nil, password: String? = nil, saveCredentials: Bool) {

        // Update existing connection if it exists, else create new
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].username = username
            if let name = name {
                items[index].name = name
            }
            items[index].saveCredentialsPreference = saveCredentials
            save()
        } else {
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
            } else {
                debugLog("⏭️ saveCredentials=true but no password provided - skipping keychain operation", category: "SavedConnections")
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

        guard let passwordData = password.data(using: .utf8) else {
            return
        }
        
        // First try to update existing password
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname
        ]
        
        let updateAttributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            debugLog("💾 Password successfully updated in keychain", category: "SavedConnections")
        } else if updateStatus == errSecItemNotFound {
            debugLog("💾 No existing password found, creating new entry", category: "SavedConnections")
            
            // Create new entry since none exists
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "VolumeControl",
                kSecAttrAccount as String: hostname,
                kSecValueData as String: passwordData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            if addStatus != errSecSuccess {
                debugLog("💾 Failed to add new password to keychain.", category: "SavedConnections")
            } else {
                debugLog("💾 Password successfully added to keychain", category: "SavedConnections")
            }
        } else {
            debugLog("💾 Failed to update password in keychain: \(updateStatus)", category: "SavedConnections")
        }
    }
    
    private func removePassword(for hostname: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: hostname
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
    }
    
    func hostKeyFingerprint(for hostname: String) -> String? {
        return items.first(where: { $0.hostname == hostname })?.hostKeyFingerprint
    }

    func hostKeyType(for hostname: String) -> String? {
        return items.first(where: { $0.hostname == hostname })?.hostKeyType
    }

    /// Every host-key fingerprint the user has accepted for `hostname`. Empty
    /// when the host has never been pinned (trust-on-first-use). Unions the
    /// stored set with the legacy single `hostKeyFingerprint` so connections
    /// saved before the set existed migrate transparently.
    func trustedHostKeyFingerprints(for hostname: String) -> Set<String> {
        guard let connection = items.first(where: { $0.hostname == hostname }) else { return [] }
        var trusted = Set(connection.hostKeyFingerprints ?? [])
        if let legacy = connection.hostKeyFingerprint {
            trusted.insert(legacy)
        }
        return trusted
    }

    /// Records `fingerprint` as the most-recently-observed key for `hostname`
    /// (shown as the connection's verification code) and adds it to the set of
    /// keys trusted for that host. A harmless no-op overwrite when the key
    /// hasn't changed; the mechanism by which a user-confirmed reconnect after
    /// a mismatch establishes new trust. No-ops if `hostname` has no row yet —
    /// callers must ensure the row exists first (e.g. after `add(...)`).
    ///
    /// A nil→non-nil transition is expected exactly once per connection:
    /// either this is a brand-new host's first-ever connect, or an existing
    /// user's first connect after updating to a build that has pinning —
    /// both are silent by design. If a connection that has *already*
    /// connected before (`hasConnectedBefore`) still has no fingerprint at
    /// pin time, this is that one-time backfill: logged for the developer,
    /// never surfaced to the user. Repeated occurrences for the same host
    /// would indicate pinning isn't persisting.
    func updateHostKeyFingerprint(_ hostname: String, fingerprint: String, keyType: String) {
        guard let index = items.firstIndex(where: { $0.hostname == hostname }) else { return }

        if items[index].hostKeyFingerprint == nil && items[index].hasConnectedBefore {
            debugLog("⚠️ Host key fingerprint backfilled for pre-existing connection '\(hostname)' with no prior baseline — expected once per legacy connection; repeated occurrences for the same host indicate pinning isn't persisting", category: "SavedConnections")
        }

        items[index].hostKeyFingerprint = fingerprint
        items[index].hostKeyType = keyType
        var trusted = items[index].hostKeyFingerprints ?? []
        if !trusted.contains(fingerprint) {
            trusted.append(fingerprint)
        }
        items[index].hostKeyFingerprints = trusted
        save()
    }

    func getSaveCredentialsPreference(for hostname: String) -> Bool {

        // Return the user's preference, with smart defaults for legacy connections
        if let connection = items.first(where: { $0.hostname == hostname }) {

            if let preference = connection.saveCredentialsPreference {
                // User has explicitly set a preference
                return preference
            } else {
                // Legacy connection - check if password actually exists
                let passwordExists = password(for: hostname) != nil
                return passwordExists  // Default to true if password exists, false if not
            }
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
