import SwiftUI

struct OnboardingNetworkAccess: View {

    @State private var showPermission: Bool = false

    var body: some View {
        VStack(spacing:0) {
            Image(systemName: "house.badge.wifi.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.green, .tertiary)
                .font(.system(size: 44, weight: .bold))
            Text("One thing first!")
                .font(.title2).bold()
            Text("Control needs local network access to find the Mac you’d like to remotely control.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Group{
                Text("Control will ask your for permission to connect to devices on your local network.")
                Text("This allows Control to find and connect to the Mac you’d like to remotely control.")
                Text("Control will never connect to devices on your local network automatically.")
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()
            Button{
                print("ok")
            } label: {
                Text("Continue")
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        OnboardingNetworkAccess()
    }
}
