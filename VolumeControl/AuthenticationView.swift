import SwiftUI

struct AuthenticationView: View {
    let name: String
    @Binding var username: String
    @Binding var password: String
    @Binding var saveCredentials: Bool
    @State private var customName: String = ""
    let onSuccess: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Computer")) {
                    Text(name)
                        .font(.headline)
                    
                    if saveCredentials {
                        TextField("Custom name (optional)", text: $customName)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                }
                
                Section(header: Text("Credentials")) {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    
                    Toggle("Save credentials for quick connect", isOn: $saveCredentials)
                }
                
                Section {
                    Button("Connect") {
                        onSuccess(saveCredentials && !customName.isEmpty ? customName : nil)
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Connect")
            .navigationBarItems(trailing: Button("Cancel", action: onCancel))
        }
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(
            name: "Test Computer",
            username: .constant("testuser"),
            password: .constant(""),
            saveCredentials: .constant(false),
            onSuccess: { _ in },
            onCancel: {}
        )
    }
}
