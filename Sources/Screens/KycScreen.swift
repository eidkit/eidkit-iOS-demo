import SwiftUI
import EidKit

struct KycScreen: View {

    @StateObject private var vm = KycViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    content
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            if case .success(let s) = vm.state {
                ExportBar(state: s, onExport: vm.exportToPdf, onRetry: { vm.retry(); dismiss() })
            }
        }
        .background(Color.surfaceDark.ignoresSafeArea())
        .navigationTitle("kyc_title")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboardOnTap()
        .sheet(isPresented: Binding(
            get: { vm.state.saveDialog != nil && !BiometricStore.neverAsk() },
            set: { if !$0 { vm.dismissSaveDialog() } }
        )) {
            if var dialog = vm.state.saveDialog {
                SaveCredentialsSheet(
                    state: Binding(
                        get: { vm.state.saveDialog ?? dialog },
                        set: { dialog = $0; vm.onSaveDialogToggle(saveCan: $0.saveCan, savePin: $0.savePin) }
                    ),
                    onConfirm: vm.confirmSave,
                    onDismiss: vm.dismissSaveDialog,
                    onNeverAsk: vm.neverAskSave
                )
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
            }
        }
        .task { await vm.tryBiometricLoad() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .input(let s):    KycInputContent(state: s, vm: vm)
        case .scanning(let s): KycScanningContent(state: s)
        case .success(let s):  KycSuccessContent(result: s.result)
        case .error(let msg):  ErrorContent(message: msg, onRetry: vm.retry)
        }
    }
}

// MARK: - Input

private struct KycInputContent: View {
    let state: KycState.Input
    let vm: KycViewModel
    @FocusState private var focus: Field?
    @State private var hasCredentials = BiometricStore.hasCredentials()
    enum Field { case can, pin }

    var body: some View {
        VStack(spacing: 16) {
            PinField(label: String(localized: "label_can"),
                     maxLength: 6, value: binding(\.can, vm.onCanChange),
                     helpImageName: "can_location",
                     maskable: true,
                     onClear: { vm.onCanChange("") }) {
                focus = .pin
            }
            .focused($focus, equals: .can)

            PinField(label: String(localized: "label_auth_pin"),
                     maxLength: 4, value: binding(\.pin, vm.onPinChange),
                     maskable: true,
                     onClear: { vm.onPinChange("") }) { }
            .focused($focus, equals: .pin)

            VStack(spacing: 8) {
                Toggle(String(localized: "kyc_include_photo"), isOn: Binding(
                    get: { state.includePhoto }, set: vm.onPhotoToggle))
                .toggleStyle(CheckboxToggleStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(String(localized: "kyc_include_signature"), isOn: Binding(
                    get: { state.includeSignature }, set: vm.onSignatureToggle))
                .toggleStyle(CheckboxToggleStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasCredentials {
                HStack {
                    Spacer()
                    Button {
                        BiometricStore.clear()
                        hasCredentials = false
                        vm.onCanChange("")
                        vm.onPinChange("")
                    } label: {
                        Text(String(localized: "bio_forget"))
                            .font(.caption)
                            .foregroundStyle(Color.errorRed)
                    }
                    .buttonStyle(.plain)
                }
            }

            if state.canSubmit {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    vm.startScan(alertMessage: String(localized: "nfc_alert_read", locale: appLocale))
                } label: {
                    Text(String(localized: "action_scan_card")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.electricBlue)
            }
        }
        .onAppear { hasCredentials = BiometricStore.hasCredentials() }
    }

    private func binding(_ kp: WritableKeyPath<KycState.Input, String>, _ setter: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { state[keyPath: kp] }, set: setter)
    }
}

// MARK: - Scanning

private struct KycScanningContent: View {
    let state: KycState.Scanning

    private let allSteps: [ReadEvent] = [
        .connectingToCard, .establishingPace, .readingPhoto,
        .readingSignatureImage, .verifyingPassiveAuth,
        .verifyingPin, .readingIdentity, .verifyingActiveAuth,
    ]

    var body: some View {
        VStack(spacing: 10) {
            if state.cardConnected {
                CardConnectedWarning()
            }
            ForEach(Array(allSteps.enumerated()), id: \.offset) { _, step in
                WizardStep(label: step.label, state: stepState(for: step))
            }
        }
    }

    private func stepState(for step: ReadEvent) -> StepState {
        if state.completedSteps.contains(where: { $0 == step }) { return .done }
        if state.activeStep == step { return .active }
        if step == .readingPhoto && !state.includePhoto { return .skipped }
        if step == .readingSignatureImage && !state.includeSignature { return .skipped }
        return .pending
    }
}

// MARK: - Success

private struct KycSuccessContent: View {
    let result: ReadResult

    var body: some View {
        ResultCard(
            title: result.identity.map { "\($0.firstName) \($0.lastName)" }
                ?? String(localized: "result_passive_auth_valid"),
            isError: false
        ) {
            if let photoData = result.photo,
               let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 125)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
            if let sigData = result.signatureImage,
               let sigImage = UIImage(data: sigData) {
                ResultRow(label: String(localized: "result_signature_image_label"), value: "")
                Image(uiImage: sigImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .padding(.bottom, 8)
            }
            if let id = result.identity {
                ResultRow(label: String(localized: "result_cnp_label"), value: id.cnp)
                ResultRow(label: String(localized: "result_dob_label"), value: formatDob(id.dateOfBirth))
                ResultRow(label: String(localized: "result_nationality_label"), value: id.nationality)
            }
            if let pd = result.personalData {
                if let v = pd.birthPlace    { ResultRow(label: String(localized: "result_birthplace_label"), value: v) }
                if let v = pd.address       { ResultRow(label: String(localized: "result_address_label"), value: v) }
                if let v = pd.documentNumber { ResultRow(label: String(localized: "result_document_label"), value: v) }
                if let v = pd.issueDate     { ResultRow(label: String(localized: "result_issue_date_label"), value: formatDob(v)) }
                if let v = pd.expiryDate    { ResultRow(label: String(localized: "result_expiry_label"), value: formatDob(v)) }
                if let v = pd.issuingAuthority { ResultRow(label: String(localized: "result_issuing_authority_label"), value: v) }
            }
            passiveAuthRows
            activeAuthRows
        }
    }

    @ViewBuilder private var passiveAuthRows: some View {
        switch result.passiveAuth {
        case .valid(let dsc, let issuer):
            ResultRow(label: String(localized: "result_passive_auth_valid"), value: "✓")
            ResultRow(label: String(localized: "result_dsc_subject_label"), value: dsc)
            ResultRow(label: String(localized: "result_issuer_label"), value: issuer)
        case .invalid(let reason):
            ResultRow(label: String(localized: "result_passive_auth_invalid"), value: reason)
        case .notSupported:
            ResultRow(label: String(localized: "result_passive_auth_not_supported_label"),
                      value: String(localized: "result_passive_auth_not_supported_value"))
        }
    }

    @ViewBuilder private var activeAuthRows: some View {
        switch result.activeAuth {
        case .verified(let cert):
            ResultRow(label: String(localized: "result_active_auth_verified"), value: "✓")
            ResultRow(label: String(localized: "result_chip_cert_label"), value: cert)
        case .failed(let reason):
            ResultRow(label: String(localized: "result_active_auth_failed"), value: reason)
        case .skipped:
            EmptyView()
        }
    }
}

// MARK: - Export bar

private struct ExportBar: View {
    let state: KycState.Success
    let onExport: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            exportButton
            Button(action: onRetry) {
                Text(String(localized: "action_try_again")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var exportButton: some View {
        switch state.exportState {
        case .idle:
            Button(action: onExport) {
                Text(String(localized: "action_export_pdf")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)

        case .exporting:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8)
                Text(String(localized: "kyc_export_generating"))
                    .font(.subheadline).foregroundStyle(.white)
            }

        case .done(let url):
            Button {
                UIApplication.shared.open(url)
            } label: {
                Text(String(localized: "kyc_export_saved")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.successGreen)

        case .failed(let msg):
            Text(String(format: String(localized: "kyc_export_error"), msg))
                .font(.caption).foregroundStyle(Color.errorRed)
        }
    }
}

// MARK: - Helpers

private extension KycState {
    var saveDialog: SaveDialogState? {
        if case .success(let s) = self { return s.saveDialog }
        return nil
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(configuration.isOn ? Color.electricBlueLight : Color.white.opacity(0.5))
                .onTapGesture { configuration.isOn.toggle() }
            configuration.label
                .font(.subheadline)
                .foregroundStyle(.white)
        }
    }
}
