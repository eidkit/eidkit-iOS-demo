import SwiftUI

struct PinField: View {

    let label: String
    let maxLength: Int
    @Binding var value: String
    var helpImageName: String? = nil
    var maskable: Bool = false
    var onClear: (() -> Void)? = nil
    var onComplete: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var showHelp = false

    @State private var userVisible = false
    @State private var maskedUpTo: Int = 0
    @State private var prevLength: Int = 0
    @State private var maskTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label row
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
                Spacer()
                if maskable {
                    Button {
                        userVisible.toggle()
                    } label: {
                        Image(systemName: userVisible ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Digit boxes row
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(0..<maxLength, id: \.self) { index in
                        let isFilled = index < value.count
                        let digit: String = isFilled
                            ? String(value[value.index(value.startIndex, offsetBy: index)])
                            : ""
                        let isActive = focused && index == min(value.count, maxLength - 1)
                        let showDot = maskable && !userVisible && isFilled && index < maskedUpTo

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
                            Text(isFilled ? (showDot ? "•" : digit) : "")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        }
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                    }
                }
                // "Șterge" clear link beside digit boxes
                if maskable, let clear = onClear {
                    Button {
                        maskTask?.cancel()
                        maskedUpTo = 0
                        prevLength = 0
                        clear()
                    } label: {
                        Text(String(localized: "action_clear"))
                            .font(.caption)
                            .underline()
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .opacity(value.isEmpty ? 0 : 1)
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
        .onChange(of: value) { new in
            guard maskable && !userVisible else {
                maskedUpTo = new.count
                prevLength = new.count
                return
            }
            let cur = new.count
            let singleKeystroke = cur == prevLength + 1
            prevLength = cur
            if singleKeystroke {
                // Cancel any previous timer and start a fresh 1s countdown
                maskTask?.cancel()
                let countAtType = cur
                maskTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    maskedUpTo = max(maskedUpTo, countAtType)
                }
            } else {
                // Biometric pre-fill or paste: mask immediately
                maskedUpTo = cur
            }
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
