import SwiftUI
import MultiBlur

struct AuthenticationView: View {
    let mode: Mode
    let existingHost: String?
    let existingName: String?

    @State private var hostname: String
    @State private var nickname: String
    @State private var isPopoverPresented = false
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    @Binding var username: String
    @Binding var password: String
    @Binding var saveCredentials: Bool

    let onSuccess: (String, String?) -> Void // (hostname, nickname?)
    let onCancel: () -> Void

    enum Field: Hashable {
        case hostname
        case nickname
        case username
        case password
    }

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
            case .add: return true
            case .edit, .authenticate: return false
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
         onCancel: @escaping () -> Void)
    {
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
                                .padding(.trailing, 4)

                            Text("Must be on the same Wi-Fi network with Remote Login enabled. ")
                                + Text("Learn more…")
                                .foregroundStyle(.tint)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            isPopoverPresented = true
                        }
                        .popover(isPresented: $isPopoverPresented) {
                            NavigationView {
                                URLWebView(urlString: "https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac")
                                    .navigationBarItems(trailing: Button("Done") {
                                        isPopoverPresented = false
                                    })
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                    }
                }
                if mode != .authenticate {
                    Section("Connection") {
                        if mode.showsHostField {
                            TextField("Hostname or IP", text: $hostname)
                                .focused($focusedField, equals: .hostname)
                                .onSubmit {
                                    focusedField = .nickname
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            Text(existingHost ?? "")
                                .foregroundStyle(.secondary)
                        }

                        TextField("Nickname (optional)", text: $nickname)
                            .focused($focusedField, equals: .nickname)
                            .onSubmit {
                                focusedField = .username
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section {
                        Text("Enter the username and password you use to log in to \(hostname.isEmpty ? "this Mac" : hostname).")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .listRowBackground(Color.clear)
                    .padding(.top, 16)
                    .padding(.vertical, 24)
                    .listSectionSpacing(0)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                Section{
                    TextField("Username" + (mode == .add ? " (Optional)" : ""), text: $username)
                        .focused($focusedField, equals: .username)
                        .onSubmit {
                            focusedField = .password
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password" + (mode == .add ? " (Optional)" : ""), text: $password)
                        .focused($focusedField, equals: .password)
                        .onSubmit {
                            handleSubmit()
                        }
                        .textContentType(.password)
                        .submitLabel(.done)

                    Toggle("Save for one-tap connect", isOn: $saveCredentials)
                }
                Button {
                    handleSubmit()
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.regular)
                        } else {
                            Text(mode.saveButtonTitle)
                                .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
                        }
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .tint(.accentColor)
                    .foregroundStyle(.tint)
                    .fontWeight(.bold)
                }
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.gray)
                .frame(maxWidth: .infinity)
                .disabled(!canSubmit || isConnecting)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            .contentMargins(.top, 0)
            .onAppear {
                if mode == .authenticate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        focusedField = .username
                    }
                }
            }
            .navigationTitle(mode != .authenticate ? mode.title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.saveButtonTitle) {
                        handleSubmit()
                    }
                    .disabled(!canSubmit)
                }

            }
            .navigationBarHidden(mode == .authenticate)
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .add:
            return !hostname.isEmpty
        case .authenticate:
            return !username.isEmpty && !password.isEmpty
        case .edit:
            return true
        }
    }

    private func handleSubmit() {
        guard canSubmit else { return }
        isConnecting = true
        onSuccess(
            mode == .add ? hostname : (existingHost ?? ""),
            !nickname.isEmpty ? nickname : nil
        )
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(
            mode: .authenticate,
            username: .constant("User"),
            password: .constant("••••"),
            saveCredentials: .constant(true),
            onSuccess: { _, _ in },
            onCancel: {}
        )
    }
}
