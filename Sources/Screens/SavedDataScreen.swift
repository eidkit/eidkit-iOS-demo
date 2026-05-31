import SwiftUI

struct SavedDataScreen: View {

    @State private var hasCredentials = BiometricStore.hasCredentials()
    @State private var emails = EmailStore.all()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfaceDark.ignoresSafeArea()
                List {
                    credentialsSection
                    emailsSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(String(localized: "saved_data_title"))
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            hasCredentials = BiometricStore.hasCredentials()
            emails = EmailStore.all()
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section(String(localized: "saved_data_section_credentials")) {
            CredentialRow(
                label:  String(localized: "saved_data_credentials_label"),
                saved:  hasCredentials,
                onClear: {
                    BiometricStore.clear()
                    hasCredentials = BiometricStore.hasCredentials()
                }
            )
        }
    }

    // MARK: - Emails

    private var emailsSection: some View {
        Section(String(localized: "saved_data_section_emails")) {
            if emails.isEmpty {
                Text(String(localized: "saved_data_no_emails"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
            } else {
                ForEach(emails, id: \.clientId) { entry in
                    EmailRow(
                        serviceName: entry.serviceName.isEmpty ? entry.clientId : entry.serviceName,
                        email:       maskEmail(entry.email),
                        onForget:    {
                            EmailStore.forget(clientId: entry.clientId)
                            emails = EmailStore.all()
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Subviews

private struct CredentialRow: View {
    let label:   String
    let saved:   Bool
    let onClear: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(saved ? Color.white : Color.white.opacity(0.45))
                Text(saved
                    ? String(localized: "saved_data_field_saved")
                    : String(localized: "saved_data_field_not_saved"))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            if saved {
                Button(String(localized: "saved_data_action_clear"), role: .destructive, action: onClear)
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.red)
            }
        }
        .listRowBackground(Color.white.opacity(0.07))
    }
}

private struct EmailRow: View {
    let serviceName: String
    let email:       String
    let onForget:    () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceName)
                    .foregroundStyle(Color.white)
                Text(email)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer()
            Button(String(localized: "saved_data_action_forget"), role: .destructive, action: onForget)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
        }
        .listRowBackground(Color.white.opacity(0.07))
    }
}

private func maskEmail(_ email: String) -> String {
    guard let atIdx = email.firstIndex(of: "@") else { return email }
    let local  = email[email.startIndex..<atIdx]
    let domain = email[atIdx...]
    let visible = local.prefix(2)
    return "\(visible)···\(domain)"
}
