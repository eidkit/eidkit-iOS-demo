import SwiftUI

struct PinField: View {

    let label: String
    let maxLength: Int
    @Binding var value: String
    var helpImageName: String? = nil
    var onComplete: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
                if helpImageName != nil {
                    Button { showHelp = true } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(Color.electricBlueLight)
                    }
                    .buttonStyle(.plain)
                }
            }

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
        .sheet(isPresented: $showHelp) {
            if let imageName = helpImageName {
                VStack(spacing: 16) {
                    if let img = loadBundleImage(named: imageName) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                    Text(String(localized: "can_tooltip_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

/// Loads a loose bundle resource image (not in asset catalog), trying common extensions.
private func loadBundleImage(named name: String) -> UIImage? {
    if let img = UIImage(named: name) { return img }
    for ext in ["jpg", "jpeg", "png"] {
        if let path = Bundle.main.path(forResource: name, ofType: ext),
           let img = UIImage(contentsOfFile: path) { return img }
    }
    return nil
}
