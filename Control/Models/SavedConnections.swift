import Foundation
import Security

class SavedConnections: ObservableObject {
    @Published private(set) var items: [SavedConnection] = []
    private let saveKey = "SavedConnections"
    /// The backing store. Injectable so tests use a throwaway suite instead of
    /// the app's real `UserDefaults.standard`.
    private let defaults: UserDefaults

    struct SavedConnection: Codable, Identifiable {
        let id: UUID
        var hostname: String
        var name: String?
        var username: String?
        let lastUsed: Date
        var hasConnectedBefore: Bool
        var enabledPlatforms: Set<String>
        var lastViewedPlatform: String?
        var saveCredentialsPreference: Bool?  // nil = legacy
        /// Host keys the user has accepted for this Mac, at most one per key
        /// type (a Mac can legitimately offer more than one algorithm). A
        /// confirmed key change replaces the entry of the same type rather than
        /// accumulating, so a superseded key stops being trusted. nil = never pinned.
        var trustedHostKeys: [TrustedHostKey]?

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
            self.trustedHostKeys = nil
        }
    }

    /// A trusted host key: its fingerprint plus the algorithm it was negotiated
    /// with, so the verification screen can point at the right file on the Mac.
    struct TrustedHostKey: Codable, Equatable {
        let fingerprint: String
        let keyType: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }
    
    func add(hostname: String, name: String? = nil, username: String? = nil, password: String? = nil, saveCredentials: Bool) {

        // Update existing connection if it exists, else create new
        if let index = index(for: hostname) {
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

        if let index = index(for: hostname) {
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
        return connection(for: hostname)?.username
    }
    
    func password(for hostname: String) -> String? {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: canonicalHostname(hostname),
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
        
        let account = canonicalHostname(hostname)

        // First try to update existing password
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VolumeControl",
            kSecAttrAccount as String: account
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
                kSecAttrAccount as String: account,
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
            kSecAttrAccount as String: canonicalHostname(hostname)
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
    }
    
    /// Matches a stored connection to `hostname` case-insensitively. Bonjour
    /// preserves the Mac's advertised capitalization while a hand-typed host is
    /// usually lowercase, yet both resolve to the same Mac (mDNS/DNS names are
    /// case-insensitive). Every lookup in this type routes through here, so the
    /// two spellings can't end up as separate rows with host-key trust on one
    /// and the setup state on the other.
    private func index(for hostname: String) -> Int? {
        items.firstIndex { $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame }
    }

    /// The spelling a row is stored under. Keychain items are keyed by an exact
    /// account string, so credential calls resolve through this instead of using
    /// whatever casing the caller happened to hold.
    private func canonicalHostname(_ hostname: String) -> String {
        index(for: hostname).map { items[$0].hostname } ?? hostname
    }

    /// The stored row for `hostname`, for callers that would otherwise match on
    /// `hostname` themselves and reintroduce a case-sensitive lookup.
    func connection(for hostname: String) -> SavedConnection? {
        index(for: hostname).map { items[$0] }
    }

    /// The keys the user has accepted for `hostname` (usually one). Empty when
    /// the host has never been pinned — the trust-on-first-use case.
    func trustedHostKeys(for hostname: String) -> [TrustedHostKey] {
        index(for: hostname).map { items[$0].trustedHostKeys ?? [] } ?? []
    }

    /// The trusted fingerprints as a set, for the transport's pinning check.
    func trustedHostKeyFingerprints(for hostname: String) -> Set<String> {
        Set(trustedHostKeys(for: hostname).map(\.fingerprint))
    }

    /// Records `info` as trusted for `hostname`. Upserts by key type: a new
    /// fingerprint for an already-trusted type *replaces* the old one, so a
    /// confirmed key change stops trusting the superseded key; a new key type
    /// is added alongside. A no-op (no write) when the key is already trusted,
    /// so a normal reconnect doesn't churn the store. No-ops if the row doesn't
    /// exist yet — callers pin after `add(...)` has created it.
    func pinHostKey(_ info: SSHHostKeyInfo, for hostname: String) {
        guard let index = index(for: hostname) else { return }
        var keys = items[index].trustedHostKeys ?? []
        if let existing = keys.firstIndex(where: { $0.keyType == info.keyType }) {
            guard keys[existing].fingerprint != info.fingerprint else { return }
            keys[existing] = TrustedHostKey(fingerprint: info.fingerprint, keyType: info.keyType)
        } else {
            keys.append(TrustedHostKey(fingerprint: info.fingerprint, keyType: info.keyType))
        }
        items[index].trustedHostKeys = keys
        save()
    }

    func getSaveCredentialsPreference(for hostname: String) -> Bool {

        // Return the user's preference, with smart defaults for legacy connections
        if let saved = connection(for: hostname) {

            if let preference = saved.saveCredentialsPreference {
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
        guard let data = defaults.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        defaults.set(encoded, forKey: saveKey)
    }
    
    func remove(hostname: String) {
        // Resolve the stored spelling first: the Keychain entry is keyed by it,
        // and it can't be looked up once the row is gone.
        let account = canonicalHostname(hostname)

        // Remove from saved items
        items.removeAll { $0.hostname.caseInsensitiveCompare(hostname) == .orderedSame }
        save()

        // Remove password from keychain
        removePassword(for: account)
    }

    /// Moves a saved connection to a new hostname, carrying everything with
    /// it: row fields, trusted host keys, and the Keychain password entry.
    /// Used by the key-verified address repair, where the pinned identity
    /// answered at a new address, so the trust genuinely belongs to the new
    /// name. No-ops if the old row doesn't exist or a row already holds the
    /// new hostname (callers exclude that case before offering the repair).
    /// Returns whether the move happened, so a caller that would otherwise
    /// connect to an unrepaired row can stop instead.
    @discardableResult
    func updateHostname(from oldHostname: String, to newHostname: String) -> Bool {
        guard let index = index(for: oldHostname),
              !items.contains(where: { $0.hostname.caseInsensitiveCompare(newHostname) == .orderedSame }) else { return false }
        let migratingPassword = password(for: items[index].hostname)
        let previousHostname = items[index].hostname
        items[index].hostname = newHostname
        save()
        if let migratingPassword {
            savePassword(migratingPassword, for: newHostname)
            removePassword(for: previousHostname)
        }
        return true
    }

    /// Renames a row in place, leaving its address and trust untouched. The
    /// address repair uses this so the list stops showing the old name after
    /// the alert announced the new one.
    func updateName(_ name: String, for hostname: String) {
        guard let index = index(for: hostname), items[index].name != name else { return }
        items[index].name = name
        save()
    }

    func markAsConnected(_ hostname: String) {
        if let index = index(for: hostname) {
            items[index].hasConnectedBefore = true
            save()
        }
    }

    func updateEnabledPlatforms(_ hostname: String, platforms: Set<String>) {
        if let index = index(for: hostname) {
            items[index].enabledPlatforms = platforms
            save()
        }
    }

    func hasConnectedBefore(_ hostname: String) -> Bool {
        return connection(for: hostname)?.hasConnectedBefore ?? false
    }

    func enabledPlatforms(_ hostname: String) -> Set<String> {
        return connection(for: hostname)?.enabledPlatforms ?? []
    }

    func updateLastViewedPlatform(_ hostname: String, platform: String) {
        if let index = index(for: hostname) {
            items[index].lastViewedPlatform = platform
            save()
        }
    }

    func lastViewedPlatform(_ hostname: String) -> String? {
        return connection(for: hostname)?.lastViewedPlatform
    }
}
