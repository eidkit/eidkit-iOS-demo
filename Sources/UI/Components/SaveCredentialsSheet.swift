import SwiftUI

struct SaveDialogState {
    var scannedCan:  String
    var scannedPin:  String
    var scannedPin2: String
    var saveCan:     Bool
    var savePin:     Bool
    var savePin2:    Bool
    var showPin2Row: Bool
}

struct SaveCredentialsSheet: View {
    @Binding var state: SaveDialogState
    let onConfirm:  () -> Void
    let onDismiss:  () -> Void
    let onNeverAsk: () -> Void

    var body: some View {
        content
            .background(Color.surfaceDark) // fallback for < 16.4
            .modifier(DarkSheetBackground())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "bio_save_title"))
                .font(.headline)
                .foregroundStyle(.white)
            Spacer().frame(height: 4)
            Text(String(localized: "bio_save_message"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer().frame(height: 8)

            ToggleRow(label: String(localized: "bio_save_can"),
                      isOn: $state.saveCan)
            ToggleRow(label: String(localized: "bio_save_pin_auth"),
                      isOn: $state.savePin)
                .opacity(state.showPin2Row ? 0 : 1)
                .frame(height: state.showPin2Row ? 0 : nil)
            if state.showPin2Row {
                ToggleRow(label: String(localized: "bio_save_pin_sign"),
                          isOn: $state.savePin2)
            }

            Spacer().frame(height: 16)

            Button(action: onConfirm) {
                Text(String(localized: "bio_save_yes")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)

            Button(action: onDismiss) {
                Text(String(localized: "bio_save_no")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(action: onNeverAsk) {
                Text(String(localized: "bio_save_never"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .padding(.bottom, 8)
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.electricBlueLight : Color.white.opacity(0.5))
                .onTapGesture { isOn.toggle() }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DarkSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(Color.surfaceDark)
        } else {
            content
        }
    }
}
