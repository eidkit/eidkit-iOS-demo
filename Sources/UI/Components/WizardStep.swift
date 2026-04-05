import SwiftUI

enum StepState {
    case pending, active, done, skipped
}

struct WizardStep: View {

    let label: String
    let state: StepState

    var body: some View {
        HStack(spacing: 12) {
            stepIcon
            Text(label)
                .font(.subheadline)
                .foregroundStyle(labelColor)
            Spacer()
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.successGreen)
        case .active:
            ProgressView()
                .scaleEffect(0.8)
                .tint(Color.electricBlueLight)
                .frame(width: 20, height: 20)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.white.opacity(0.3))
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(Color.white.opacity(0.3))
        }
    }

    private var labelColor: Color {
        switch state {
        case .done:    return .white
        case .active:  return Color.electricBlueLight
        case .skipped: return Color.white.opacity(0.3)
        case .pending: return Color.white.opacity(0.4)
        }
    }
}
