import SwiftUI

/// Shown in the UI while the form is ready — iOS NFC sheet is system-managed,
/// this is just an in-app visual cue that the card scan is about to start.
struct NfcPromptView: View {
    var body: some View {
        HStack(spacing: 14) {
            PulsingNfcIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text("nfc_prompt_title")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text("nfc_prompt_body")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.electricBlueLight.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct PulsingNfcIcon: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            // Two staggered pulse rings
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Color.electricBlueLight, lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                    .scaleEffect(animate ? 2.2 : 1.0)
                    .opacity(animate ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 2.0)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 1.0),
                        value: animate
                    )
            }
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.electricBlueLight)
        }
        .frame(width: 44, height: 44)
        .onAppear { animate = true }
    }
}
