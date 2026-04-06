import SwiftUI

/// Thin, semi-transparent demo mode indicator shown below each screen's navigation bar.
struct DemoModeBanner: View {
    var body: some View {
        Text(String(localized: "demo_mode_banner"))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Color.errorRed.opacity(0.7))
    }
}
