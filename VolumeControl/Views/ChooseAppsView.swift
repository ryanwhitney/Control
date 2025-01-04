import SwiftUI

struct ChooseAppsView: View {
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let onComplete: (Set<String>) -> Void
    
    @State private var selectedPlatforms: Set<String> = []
    
    var body: some View {
        ZStack {
            Form {
                Section {
                    VStack(alignment: .center){
                        Image(systemName: "macbook.and.iphone")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 60)
                            .foregroundStyle(.green, .quaternary)
                        
                        Text("Which apps would you like to control?")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("You can change these anytime.")
                            .foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                Section {
                    ForEach(PlatformRegistry.allPlatforms, id: \.id) { platform in
                        Toggle(isOn: Binding(
                            get: { selectedPlatforms.contains(platform.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedPlatforms.insert(platform.id)
                                } else {
                                    selectedPlatforms.remove(platform.id)
                                }
                            }
                        )) {
                            Text(platform.name)
                        }
                    }
                }
            }
            VStack {
                Spacer()
                VStack(){
                    Button(action: {
                        onComplete(selectedPlatforms)
                    }) {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedPlatforms.isEmpty)
                }.background(.black)
            }
        }
        .navigationTitle("Choose Apps")
    }
}

#Preview {
    let client = SSHClient()
    client.connect(host: "rwhitney-mac.local", username: "ryan", password: "") { _ in }
    
    return NavigationStack {
        ChooseAppsView(
            hostname: "rwhitney-mac.local",
            displayName: "Ryan's Mac",
            sshClient: client,
            onComplete: { _ in }
        )
    }
} 
