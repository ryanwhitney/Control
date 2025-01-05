import SwiftUI

struct ChooseAppsView: View {
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let onComplete: (Set<String>) -> Void
    
    @State private var selectedPlatforms: Set<String> = Set(PlatformRegistry.allPlatforms.map { $0.id })
    
    var body: some View {
        ZStack {
            Form {
                Section {
                    VStack(alignment: .center){
                        Image(systemName: "macbook.and.iphone")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 60)
                            .foregroundStyle(.tint, .clear)
                        
                        Text("Which apps would you like to control?")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("You can change these anytime.")
                            .foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                
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
                                .font(.title3)
                                .fontWeight(.medium)
                                .padding(.vertical, 7)
                        }
                    }
                }
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
            }
            VStack {
                Spacer()
                VStack(){
                    ZStack {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .blur(radius: 50)
                            .accessibilityHidden(true)
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .blur(radius: 10)
                            .accessibilityHidden(true)
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .blur(radius: 20)
                            .accessibilityHidden(true)
                        
                        Button(action: {
                            onComplete(selectedPlatforms)
                        }) {
                            Text("Continue")
                                .padding(.vertical, 11)
                                .frame(maxWidth: .infinity)
                                .tint(.accentColor)
                                .foregroundStyle(.tint)
                                .fontWeight(.bold)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                        .buttonStyle(.bordered)
                        .tint(.gray)
                        .frame(maxWidth: .infinity)
                        .disabled(selectedPlatforms.isEmpty)
                    }
                }.background(Material.bar)
            }
        }
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
