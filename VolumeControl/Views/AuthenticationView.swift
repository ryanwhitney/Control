import SwiftUI

struct AuthenticationView: View {
    let mode: Mode
    let existingHost: String?
    let existingName: String?
    
    @State private var hostname: String
    @State private var nickname: String
    @Binding var username: String
    @Binding var password: String
    @Binding var saveCredentials: Bool
    
    let onSuccess: (String, String?) -> Void // (hostname, nickname?)
    let onCancel: () -> Void
    
    enum Mode {
        case add
        case authenticate
        
        var title: String {
            switch self {
            case .add: return "Add Computer"
            case .authenticate: return "Connect"
            }
        }
    }
    
    init(mode: Mode,
         existingHost: String? = nil,
         existingName: String? = nil,
         username: Binding<String>,
         password: Binding<String>,
         saveCredentials: Binding<Bool>,
         onSuccess: @escaping (String, String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.mode = mode
        self.existingHost = existingHost
        self.existingName = existingName
        self._hostname = State(initialValue: existingHost ?? "")
        self._nickname = State(initialValue: existingName ?? "")
        self._username = username
        self._password = password
        self._saveCredentials = saveCredentials
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }
    
    var body: some View {
        NavigationView {
            Form {
                if mode == .add {
                    Section {
                        HStack {
                            Image(systemName: "network")
                            Text("Must be on the same Wi-Fi network with Remote Login enabled.")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                
                Section("Computer") {
                    if mode == .add {
                        TextField("Hostname or IP", text: $hostname)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    } else {
                        Text(existingHost ?? "")
                            .foregroundStyle(.secondary)
                    }
                    
                    TextField("Nickname (optional)", text: $nickname)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                
                Section(mode == .add ? "Credentials (Optional)" : "Credentials") {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    
                    Toggle("Save for quick connect", isOn: $saveCredentials)
                }
                
                Section {
                    Button(mode == .add ? "Add" : "Connect") {
                        onSuccess(
                            mode == .add ? hostname : (existingHost ?? ""),
                            !nickname.isEmpty ? nickname : nil
                        )
                    }
                    .disabled(mode == .add ? hostname.isEmpty : (username.isEmpty || password.isEmpty))
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AuthenticationView(
                mode: .authenticate,
                existingName: "Test Computer",
                username: .constant("testuser"),
                password: .constant(""),
                saveCredentials: .constant(false),
                onSuccess: { _, _ in },
                onCancel: {}
            )
            
            AuthenticationView(
                mode: .add,
                username: .constant(""),
                password: .constant(""),
                saveCredentials: .constant(false),
                onSuccess: { _, _ in },
                onCancel: {}
            )
        }
    }
}
