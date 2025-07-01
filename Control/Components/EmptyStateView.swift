import SwiftUI

struct EmptyStateView: View {
    let isSearching: Bool
    let onRefresh: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if isSearching {
                ProgressView()
                    .controlSize(.large)
                Text("Searching...")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "macbook.and.iphone")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 40)
                        .foregroundStyle(.tint)
                    Text("No connections found")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Make sure your Mac is on the same network and has Remote Login enabled.")
                        .foregroundStyle(.secondary)
                    Button(action: onRefresh) {
                        Text("Refresh")
                            .foregroundStyle(.tint)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
            Spacer()
        }
    }
} 