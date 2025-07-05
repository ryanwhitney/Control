import Foundation
import Network

struct Connection: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let type: ConnectionType
    var lastUsername: String?

    enum ConnectionType {
        case bonjour(NetService)
        case manual
    }

    static func == (lhs: Connection, rhs: Connection) -> Bool {
        return lhs.host == rhs.host
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host)
    }
}

extension Connection {
    static func fromNetService(_ service: NetService, lastUsername: String? = nil) -> Connection? {
        guard let hostname = service.hostName else { return nil }
        
        let cleanHostname = hostname.replacingOccurrences(of: ".local.", with: ".local")
        
        return Connection(
            id: "net-" + cleanHostname,
            name: service.name.replacingOccurrences(of: "\\032", with: ""),
            host: cleanHostname,
            type: .bonjour(service),
            lastUsername: lastUsername
        )
    }
    
    static func fromSavedConnection(_ saved: SavedConnections.SavedConnection) -> Connection {
        return Connection(
            id: "saved-" + saved.hostname,
            name: saved.name ?? saved.hostname,
            host: saved.hostname,
            type: .manual,
            lastUsername: saved.username
        )
    }
} 