import SwiftUI

struct VolumeControlView: View {
    let host: String
    let username: String
    let password: String
    let sshClient: SSHClient

    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var connectionState: ConnectionState = .connecting
    @Environment(\.dismiss) private var dismiss
    @State private var sshOutput: String = ""

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
                    
                    Button("Test Command") {
                        testCommand()
                    }
                }
                .padding()

                ScrollView {
                    Text(sshOutput)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(height: 100)
                .background(Color.black.opacity(0.1))
                .cornerRadius(8)
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
                    self.appendOutput("Connection failed: \(error.localizedDescription)")
                case .success:
                    self.connectionState = .connected
                    self.appendOutput("Connected successfully")
                    self.getVolume()
                }
            }
        }
    }

    private func getVolume() {
        let command = "/usr/bin/osascript -e 'get volume settings'"
        appendOutput("$ \(command)")
        
        sshClient.executeCommandWithNewChannel(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.errorMessage = "Failed to get volume: \(error.localizedDescription)"
                    self.appendOutput("[Error] \(error.localizedDescription)")
                case .success(let output):
                    self.appendOutput(output)
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
        appendOutput("$ \(command)")
        
        sshClient.executeCommandWithNewChannel(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.errorMessage = "Failed to set volume: \(error.localizedDescription)"
                    self.appendOutput("[Error] \(error.localizedDescription)")
                case .success(let output):
                    self.appendOutput(output)
                    self.getVolume()
                }
            }
        }
    }

    private func testCommand() {
        let command = "say 'hello ryan'"
        appendOutput("$ \(command)")
        
        sshClient.executeCommandWithNewChannel(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.errorMessage = "Failed to run test: \(error.localizedDescription)"
                    self.appendOutput("[Error] \(error.localizedDescription)")
                case .success(let output):
                    self.appendOutput(output)
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            if text.hasPrefix("$") {
                // Command being sent
                self.sshOutput = "\(text)\n" + self.sshOutput
            } else {
                // Command output
                self.sshOutput = text + "\n" + self.sshOutput
            }
        }
    }
}
