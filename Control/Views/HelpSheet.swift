import SwiftUI
import MultiBlur

/// Chrome for the app's help sheets: title and subtitle, the caller's
/// instruction sections, an optional explainer above the mail link, and the
/// dismissing OK pill.
struct HelpSheet<Content: View, Explainer: View>: View {
    private let title: String
    private let subtitle: String
    private let mailSubject: String
    /// Prose below the reply separator, which the sheet supplies in full.
    private let mailBody: String
    private let detents: Set<PresentationDetent>
    private let content: Content
    private let explainer: Explainer

    @State private var showMailComposer = false
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        subtitle: String,
        mailSubject: String,
        mailBody: String,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: () -> Content,
        @ViewBuilder explainer: () -> Explainer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mailSubject = mailSubject
        self.mailBody = mailBody
        self.detents = detents
        self.content = content()
        self.explainer = explainer()
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.title2).bold()
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)

                content

                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        explainer
                        Button {
                            showMailComposer = true
                        } label: {
                            (Text("Have any questions, or need a hand? ")
                                .foregroundStyle(.secondary)
                                + Text("Email me anytime.")
                                .foregroundStyle(.tint))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
            }
            // No `.listStyle`: the platform default draws the rounded inset
            // card, while `.grouped` would run the steps edge to edge.
            .scrollContentBackground(.hidden)
            .listSectionSpacing(8)

            Button {
                dismiss()
            } label: {
                HStack {
                    Text("OK")
                        .multiblur([(10, 0.25), (50, 0.35)])
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .glassPillLabel()
                .fontWeight(.bold)
            }
            .glassPillButtonStyle(tint: .accentColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .background(.ultraThickMaterial)
        .themeTint(preferences.tintColorValue)
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: mailSubject,
                recipient: "ryan.whitney@me.com",
                body: "\n\n\n\n--\n" + mailBody
            )
        }
    }
}

extension HelpSheet where Explainer == EmptyView {
    init(
        title: String,
        subtitle: String,
        mailSubject: String,
        mailBody: String,
        detents: Set<PresentationDetent> = [.medium, .large],
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            mailSubject: mailSubject,
            mailBody: mailBody,
            detents: detents,
            content: content,
            explainer: { EmptyView() }
        )
    }
}

/// Numbered instructions; each step's emphasis is baked into its `Text`.
struct HelpSheetSteps: View {
    let steps: [Text]

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top) {
                    Text("\(index + 1).")
                        .frame(minWidth: 16, alignment: .leading)
                        .foregroundStyle(.secondary)
                    step
                }
                .padding(.vertical, 6)
                // One instruction, not a stray number.
                .accessibilityElement(children: .combine)
            }
        }
    }
}
