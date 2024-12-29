import Foundation

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
    
    func add(hostname: String, name: String? = nil) {
        // Don't add if already exists
        guard !items.contains(where: { $0.hostname == hostname }) else { return }
        
        let connection = SavedConnection(hostname: hostname, name: name)
        items.append(connection)
        save()
    }
    
    func updateLastUsername(for hostname: String, username: String) {
        if let index = items.firstIndex(where: { $0.hostname == hostname }) {
            items[index].username = username
            save()
        } else {
            add(hostname: hostname, name: nil)
        }
    }
    
    func lastUsername(for hostname: String) -> String? {
        return items.first(where: { $0.hostname == hostname })?.username
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
} 