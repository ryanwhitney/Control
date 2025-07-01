import Foundation
import Network
import SwiftUI

@MainActor
class NetworkScanner: ObservableObject {
    @Published private(set) var services: [NetService] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    
    private var browser: NWBrowser?
    private var lastScanTime: Date?
    
    /// Checks if a scan should automatically run (hasn't run in 30+ seconds)
    var shouldAutoScan: Bool {
        guard let lastScan = lastScanTime else { return true }
        return Date().timeIntervalSince(lastScan) > 30
    }
    
    func startScan() {
        viewLog("NetworkScanner: Starting network scan", view: "NetworkScanner")
        services.removeAll()
        errorMessage = nil
        isScanning = true
        lastScanTime = Date()
        
        browser?.cancel()
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        
        let scanner = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: parameters)
        self.browser = scanner
        
        scanner.stateUpdateHandler = { [weak self] state in
            viewLog("Network scanner state: \(state)", view: "NetworkScanner")
            Task { @MainActor in
                switch state {
                case .failed(let error):
                    viewLog("❌ Network scanner failed: \(error)", view: "NetworkScanner")
                    self?.errorMessage = error.localizedDescription
                    self?.isScanning = false
                case .ready:
                    viewLog("✓ Network scanner ready", view: "NetworkScanner")
                case .cancelled:
                    viewLog("Network scanner cancelled", view: "NetworkScanner")
                    self?.isScanning = false
                case .setup:
                    viewLog("Network scanner setting up", view: "NetworkScanner")
                case .waiting:
                    viewLog("Network scanner waiting", view: "NetworkScanner")
                @unknown default:
                    viewLog("Network scanner in unknown state: \(state)", view: "NetworkScanner")
                }
            }
        }
        
        scanner.browseResultsChangedHandler = { [weak self] results, changes in
            viewLog("Network scan found \(results.count) services", view: "NetworkScanner")
            Task { @MainActor in
                self?.services = results.compactMap { result in
                    guard case .service(let name, let type, let domain, _) = result.endpoint else {
                        viewLog("Invalid endpoint format in scan result", view: "NetworkScanner")
                        return nil
                    }
                    
                    viewLog("Found SSH service: type=\(type), domain=\(domain), name=\(String(name.prefix(3)))***", view: "NetworkScanner")
                    
                    let service = NetService(domain: domain, type: type, name: name)
                    service.resolve(withTimeout: 5.0)
                    
                    return service
                }
            }
        }
        
        viewLog("Starting network scan with 6 second timeout", view: "NetworkScanner")
        scanner.start(queue: .main)
        
        Task {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            stopScan()
        }
    }
    
    func stopScan() {
        viewLog("Network scan timeout reached", view: "NetworkScanner")
        viewLog("Final service count: \(services.count)", view: "NetworkScanner")
        browser?.cancel()
        isScanning = false
    }
    
    deinit {
        browser?.cancel()
    }
} 