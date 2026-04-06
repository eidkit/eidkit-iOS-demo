import SwiftUI

struct ResultCard<Content: View>: View {

    let title: String
    let isError: Bool
    var onRetry: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 10) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.errorRed : Color.successGreen)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .background(Color.surfaceBorder)

            // Body
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(16)

            // Retry button
            if let onRetry {
                Divider().background(Color.surfaceBorder)
                Button(action: onRetry) {
                    Text(String(localized: "action_try_again"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.electricBlue)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.surfaceBorder, lineWidth: 1)
        )
    }
}

struct ResultRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
    }
}
