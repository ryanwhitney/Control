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
        case edit
        
        var title: String {
            switch self {
            case .add: return "Add Connection"
            case .authenticate: return "Connect"
            case .edit: return "Edit Connection"
            }
        }
        
        var showsNetworkMessage: Bool {
            switch self {
            case .add, .authenticate: return true
            case .edit: return false
            }
        }
        
        var showsHostField: Bool {
            switch self {
            case .add: return true
            case .authenticate, .edit: return false
            }
        }
        
        var saveButtonTitle: String {
            switch self {
            case .add: return "Add"
            case .authenticate: return "Connect"
            case .edit: return "Save"
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
                if mode.showsNetworkMessage {
                    Section {
                        HStack {
                            Image(systemName: "network")
                            Text("Must be on the same Wi-Fi network with Remote Login enabled.")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                
                Section("Connection") {
                    if mode.showsHostField {
                        TextField("Hostname or IP", text: $hostname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(nil)
                    } else {
                        Text(existingHost ?? "")
                            .foregroundStyle(.secondary)
                    }
                    
                    TextField("Nickname (optional)", text: $nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                }
                
                Section("Credentials" + (mode == .add ? " (Optional)" : "")) {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                    
                    SecureField("Password", text: $password)
                        .textContentType(nil)
                        .submitLabel(.done)
                    
                    Toggle("Save for quick connect", isOn: $saveCredentials)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.saveButtonTitle) {
                        onSuccess(
                            mode == .add ? hostname : (existingHost ?? ""),
                            !nickname.isEmpty ? nickname : nil
                        )
                    }
                    .disabled(mode == .add ? hostname.isEmpty : (mode == .authenticate && (username.isEmpty || password.isEmpty)))
                }
            }
        }
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(
            mode: .add,
            username: .constant(""),
            password: .constant(""),
            saveCredentials: .constant(true),
            onSuccess: { _, _ in },
            onCancel: {}
        )
    }
}
