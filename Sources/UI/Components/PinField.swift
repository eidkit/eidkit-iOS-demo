import SwiftUI

struct PinField: View {

    let label: String
    let maxLength: Int
    @Binding var value: String
    var onComplete: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))

            HStack(spacing: 10) {
                ForEach(0..<maxLength, id: \.self) { index in
                    let digit: String = index < value.count
                        ? String(value[value.index(value.startIndex, offsetBy: index)])
                        : ""
                    let isActive = focused && index == min(value.count, maxLength - 1)

                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.surfaceCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        isActive ? Color.electricBlueLight : Color.surfaceBorder,
                                        lineWidth: isActive ? 2 : 1
                                    )
                            )
                        Text(digit.isEmpty ? "" : digit)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                }
            }
            // Invisible text field captures input
            .overlay(
                TextField("", text: $value)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.001)
                    .onChange(of: value) { new in
                        let filtered = String(new.filter(\.isNumber).prefix(maxLength))
                        if filtered != new { value = filtered }
                        if filtered.count == maxLength {
                            onComplete?()
                        }
                    }
            )
            .onTapGesture { focused = true }
        }
    }
}
