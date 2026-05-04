import SwiftUI
import EidKit

struct AuthScreen: View {

    @StateObject private var vm = AuthViewModel()
    @Environment(\.dismiss) private var dismiss

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
        .navigationTitle("auth_title")
        .navigationBarTitleDisplayMode(.inline)
        .hideKeyboardOnTap()
        .sheet(isPresented: Binding(
            get: {
                if case .success(let s) = vm.state { return s.saveDialog != nil && !BiometricStore.neverAsk() }
                return false
            },
            set: { if !$0 { vm.dismissSaveDialog() } }
        )) {
            if case .success(let s) = vm.state, var dialog = s.saveDialog {
                SaveCredentialsSheet(
                    state: Binding(
                        get: {
                            if case .success(let latest) = vm.state { return latest.saveDialog ?? dialog }
                            return dialog
                        },
                        set: { dialog = $0; vm.onSaveDialogToggle(saveCan: $0.saveCan, savePin: $0.savePin) }
                    ),
                    onConfirm: vm.confirmSave,
                    onDismiss: vm.dismissSaveDialog,
                    onNeverAsk: vm.neverAskSave
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .background(Color.surfaceDark)
            }
        }
        .task { await vm.tryBiometricLoad() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .input(let s):   AuthInputContent(state: s, vm: vm)
        case .scanning(let s): AuthScanningContent(state: s)
        case .success(let r): AuthSuccessContent(result: r.result, onRetry: { vm.retry(); dismiss() })
        case .error(let msg): ErrorContent(message: msg, onRetry: vm.retry)
        }
    }
}

// MARK: - Input

private struct AuthInputContent: View {
    let state: AuthState.Input
    let vm: AuthViewModel
    @FocusState private var focus: Field?
    enum Field { case can, pin }

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "auth_pin_hint"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            PinField(label: String(localized: "label_can"),
                     maxLength: 6,
                     value: Binding(get: { state.can }, set: vm.onCanChange),
                     helpImageName: "can_location",
                     maskable: true,
                     onClear: { vm.onCanChange("") }) {
                focus = .pin
            }
            .focused($focus, equals: .can)
            .onAppear { focus = .can }

            PinField(label: String(localized: "label_auth_pin"),
                     maxLength: 4,
                     value: Binding(get: { state.pin }, set: vm.onPinChange),
                     maskable: true,
                     onClear: { vm.onPinChange("") }) { }
            .focused($focus, equals: .pin)

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
    }
}

// MARK: - Scanning

private struct AuthScanningContent: View {
    let state: AuthState.Scanning

    private let allSteps: [ReadEvent] = [
        .connectingToCard, .establishingPace,
        .verifyingPassiveAuth, .verifyingPin,
        .readingIdentity, .verifyingActiveAuth,
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
        return .pending
    }
}

// MARK: - Success

private struct AuthSuccessContent: View {
    let result: ReadResult
    let onRetry: () -> Void

    private var isVerified: Bool {
        if case .verified = result.activeAuth { return true }
        return false
    }

    var body: some View {
        let title: String = {
            if isVerified, let id = result.identity {
                return "\(id.firstName) \(id.lastName)"
            }
            return isVerified
                ? String(localized: "result_active_auth_verified")
                : String(localized: "result_active_auth_failed")
        }()

        ResultCard(title: title, isError: !isVerified, onRetry: onRetry) {
            switch result.activeAuth {
            case .verified(let cert):
                ResultRow(label: String(localized: "result_active_auth_verified"), value: "✓")
                ResultRow(label: String(localized: "result_chip_cert_label"), value: cert)
            case .failed(let reason):
                ResultRow(label: String(localized: "result_active_auth_failed"), value: reason)
            case .skipped:
                EmptyView()
            }
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
            if let id = result.identity {
                ResultRow(label: String(localized: "result_cnp_label"), value: id.cnp)
                ResultRow(label: String(localized: "result_dob_label"), value: formatDob(id.dateOfBirth))
            }
            if result.claim != nil {
                ResultRow(label: String(localized: "result_claim_ready"), value: "✓")
            }
        }
    }
}
