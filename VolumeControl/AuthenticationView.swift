import SwiftUI

struct AuthenticationView: View {
    let name: String
    @Binding var username: String
    @Binding var password: String
    let onSuccess: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Connect to \(name)")
                    .font(.headline)

                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textContentType(.password)

                HStack(spacing: 20) {
                    Button("Cancel", role: .cancel, action: onCancel)
                    
                    Button("Connect") {
                        onSuccess()
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                }
            }
            .padding()
            .navigationTitle("Authentication")
        }
    }
} 