import SwiftUI

struct VolumeControlView: View {
    let host: String
    let username: String
    let password: String

    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var connectionState: ConnectionState = .connecting
    @Environment(\.dismiss) private var dismiss
    private let sshClient = SSHClient()

    enum ConnectionState {
        case connecting
        case connected
        case failed(String)
    }

    var body: some View {
        VStack {
            switch connectionState {
            case .connecting:
                ProgressView("Connecting to \(host)...")
                
            case .connected:
                Text("Volume: \(Int(volume * 100))%")
                    .padding(.top)
                
                Slider(value: $volume, in: 0...1, step: 0.01)
                    .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button("Get Volume") {
                        getVolume()
                    }
                    
                    Button("Set Volume") {
                        setVolume()
                    }
                }
                .padding()

            case .failed(let error):
                VStack {
                    Text("Connection Failed")
                        .font(.headline)
                    Text(error)
                        .foregroundColor(.red)
                    Button("Go Back") {
                        dismiss()
                    }
                    .padding()
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
        .onAppear {
            connectToSSH()
        }
    }

    private func connectToSSH() {
        sshClient.connect(host: host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.connectionState = .failed(error.localizedDescription)
                case .success:
                    self.connectionState = .connected
                    self.getVolume()
                }
            }
        }
    }

    private func getVolume() {
        // First test with a simple command
        sshClient.executeCommand("echo $PATH") { result in
            switch result {
            case .success(let output):
                print("PATH test succeeded: \(output)")
                // Now try the volume command
                self.executeVolumeCommand()
            case .failure(let error):
                print("PATH test failed: \(error)")
                self.errorMessage = "Failed to execute test command: \(error.localizedDescription)"
            }
        }
    }

    private func executeVolumeCommand() {
        let command = "/usr/bin/osascript -e 'get volume settings'"
        sshClient.executeCommand(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    print("Volume fetch error: \(error)")
                    self.errorMessage = "Failed to get volume: \(error.localizedDescription)"
                case .success(let output):
                    print("Raw volume output: \(output)")
                    // Parse the output which looks like "output volume:50, input volume:0, ..."
                    if let volumeStr = output.split(separator: ",").first,
                       let volumeNum = volumeStr.split(separator: ":").last,
                       let volumeLevel = Float(volumeNum.trimmingCharacters(in: .whitespaces)) {
                        self.volume = volumeLevel / 100.0
                    } else {
                        self.errorMessage = "Invalid volume format: \(output)"
                    }
                }
            }
        }
    }

    private func setVolume() {
        let volumeInt = Int(volume * 100)
        let command = "/usr/bin/osascript -e 'set volume output volume \(volumeInt)'"
        
        sshClient.executeCommand(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    print("Set volume error: \(error)")
                    self.errorMessage = "Failed to set volume: \(error.localizedDescription)"
                case .success(let output):
                    print("Set volume success: \(output)")
                    // Optionally refresh the volume after setting it
                    getVolume()
                }
            }
        }
    }
}
