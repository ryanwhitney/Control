import SwiftUI

struct ChooseAppsView: View {
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let onComplete: (Set<String>) -> Void
    
    @State private var selectedPlatforms: Set<String> = Set(PlatformRegistry.allPlatforms.map { $0.id })
    
    var body: some View {
        VStack {
                VStack(alignment: .center){
                    Image(systemName: "macbook.and.iphone")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 40)
                        .foregroundStyle(.tint, .clear)

                    Text("Which apps would you like to control?")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("You can change these anytime.")
                        .foregroundStyle(.secondary)
                }.multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)

            ScrollView {
                VStack(spacing: 2) {
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
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                        .background(.ultraThinMaterial)
                        .padding(.vertical, 4)
                    )
                }.padding()
            }

            }
                VStack(){
                    ZStack {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .blur(radius: 10)
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
