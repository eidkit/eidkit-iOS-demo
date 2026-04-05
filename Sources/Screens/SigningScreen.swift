import SwiftUI
import UniformTypeIdentifiers
import EidKit

struct SigningScreen: View {

    @StateObject private var vm = SigningViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var showSavePicker = false
    @State private var saveUrl: URL? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .background(Color.surfaceDark.ignoresSafeArea())
        .navigationTitle("signing_title")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboardOnTap()
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                vm.onDocumentSelected(url: url, displayName: url.lastPathComponent)
            }
        }
        .onChange(of: vm.pendingFileSave) { shouldShow in
            if shouldShow { showSavePicker = true }
        }
        .fileMover(isPresented: $showSavePicker,
                   file: tempSignedFile()) { result in
            if case .success(let url) = result {
                vm.onOutputUrlSelected(url: url)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .documentPicker:
            DocumentPickerContent { showPicker = true }
        case .input(let s):
            SigningInputContent(state: s, vm: vm, onChangePdf: vm.clearDocument)
        case .scanning(let s):
            SigningScanningContent(state: s)
        case .awaitingOutput:
            HStack(spacing: 12) {
                ProgressView().scaleEffect(0.8)
                Text(String(localized: "signing_awaiting_output"))
                    .font(.subheadline).foregroundStyle(.white)
            }
        case .success(let s):
            SigningSuccessContent(state: s, onRetry: { vm.retry(); dismiss() })
        case .error(let msg):
            ErrorContent(message: msg, onRetry: vm.retry)
        }
    }

    /// Returns the temp URL of the signed PDF in-progress, used by fileMover.
    private func tempSignedFile() -> URL {
        if case .awaitingOutput(let aw) = vm.state {
            return aw.padesCtx.tempFileUrl
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("signed.pdf")
    }
}

// MARK: - Document picker card

private struct DocumentPickerContent: View {
    let onPick: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.surfaceBorder, lineWidth: 1)
            .background(Color.surfaceCard.cornerRadius(12))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.electricBlue)
                    Text(String(localized: "signing_pick_pdf_title"))
                        .font(.headline).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(String(localized: "signing_pick_pdf_description"))
                        .font(.caption).foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button(action: onPick) {
                        Text(String(localized: "signing_pick_pdf_button"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.electricBlue)
                }
                .padding(24)
            }
            .frame(minHeight: 200)
    }
}

// MARK: - Input

private struct SigningInputContent: View {
    let state: SigningState.Input
    let vm: SigningViewModel
    let onChangePdf: () -> Void
    @FocusState private var focus: Field?
    enum Field { case can, pin }

    var body: some View {
        VStack(spacing: 0) {
            // Selected document card
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.surfaceBorder, lineWidth: 1)
                .background(Color.surfaceCard.cornerRadius(10))
                .overlay {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "signing_document_selected"))
                            .font(.caption).foregroundStyle(Color.white.opacity(0.5))
                        Text(state.documentName)
                            .font(.subheadline).foregroundStyle(.white)
                        Text(String(localized: "signing_hash_label"))
                            .font(.caption).foregroundStyle(Color.white.opacity(0.5))
                        Text(state.padesCtx.signedAttrsHash.hexString.prefix(48) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.white.opacity(0.7))
                        Button(action: onChangePdf) {
                            Text(String(localized: "signing_change_document"))
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)

            PinField(label: String(localized: "label_can"),
                     maxLength: 6,
                     value: Binding(get: { state.can }, set: vm.onCanChange)) {
                focus = .pin
            }
            .focused($focus, equals: .can)
            .onAppear { focus = .can }

            PinField(label: String(localized: "label_signing_pin"),
                     maxLength: 6,
                     value: Binding(get: { state.pin }, set: vm.onPinChange)) { }
            .focused($focus, equals: .pin)

            if state.canSubmit {
                NfcPromptView()
            }
        }
        .onChange(of: state.canSubmit) { isValid in
            if isValid {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                vm.startScan()
            }
        }
    }
}

// MARK: - Scanning

private struct SigningScanningContent: View {
    let state: SigningState.Scanning

    private let allSteps: [SignEvent] = [
        .connectingToCard, .establishingPace, .verifyingPin, .signingDocument,
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(allSteps.enumerated()), id: \.offset) { _, step in
                WizardStep(label: step.label, state: stepState(for: step))
            }
        }
    }

    private func stepState(for step: SignEvent) -> StepState {
        if state.completedSteps.contains(where: { $0 == step }) { return .done }
        if state.activeStep == step { return .active }
        return .pending
    }
}

// MARK: - Success

private struct SigningSuccessContent: View {
    let state: SigningState.Success
    let onRetry: () -> Void

    var body: some View {
        ResultCard(title: String(localized: "signing_success_saved"),
                   isError: false, onRetry: onRetry) {
            ResultRow(label: String(localized: "signing_document_selected"),
                      value: state.documentName)

            let hex = state.signResult.signature.hexString
            ResultRow(label: String(localized: "result_signature_label"),
                      value: String(hex.prefix(48)) + "…")

            Spacer(minLength: 8)
            Button {
                UIApplication.shared.open(state.outputUrl)
            } label: {
                Text(String(localized: "signing_success_open")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)
        }
    }
}

// MARK: - Data extension

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
