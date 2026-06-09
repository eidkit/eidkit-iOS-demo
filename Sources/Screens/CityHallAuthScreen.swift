import SwiftUI
import EidKit

struct CityHallAuthScreen: View {

    let input: CityHallInput
    let onDismiss: () -> Void

    @StateObject private var vm: CityHallAuthViewModel

    init(input: CityHallInput, onDismiss: @escaping () -> Void) {
        self.input = input
        self.onDismiss = onDismiss
        _vm = StateObject(wrappedValue: CityHallAuthViewModel(input: input))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfaceDark.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        content
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
            .navigationTitle(input.serviceName.isEmpty ? "SSO Login" : input.serviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .success = vm.state {
                        EmptyView()
                    } else {
                        Button(String(localized: "action_cancel")) {
                            vm.cancelScan?()
                            onDismiss()
                        }
                    }
                }
            }
            .hideKeyboardOnTap()
        }
        .onAppear {
            vm.onSuccess = { onDismiss() }
        }
        .sheet(isPresented: Binding(
            get: { vm.saveDialog != nil && !BiometricStore.neverAsk() },
            set: { if !$0 { vm.dismissSaveDialog() } }
        )) {
            if var dialog = vm.saveDialog {
                SaveCredentialsSheet(
                    state: Binding(
                        get: { vm.saveDialog ?? dialog },
                        set: { dialog = $0; vm.onSaveDialogToggle(saveCan: $0.saveCan, savePin: $0.savePin) }
                    ),
                    onConfirm: vm.confirmSave,
                    onDismiss: vm.dismissSaveDialog,
                    onNeverAsk: vm.neverAskSave
                )
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
                .background(Color.surfaceDark)
            }
        }
        .task { await vm.tryBiometricLoad() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .input(let s):      CityHallInputContent(state: s, vm: vm)
        case .scanning(let s):   CityHallScanningContent(state: s)
        case .emailInput(let s): CityHallEmailInputContent(state: s, vm: vm)
        case .otpInput(let s):   CityHallOtpInputContent(state: s, vm: vm)
        case .success(let name): CityHallSuccessContent(name: name, onDone: onDismiss)
        case .error(let msg, let traceId): ErrorContent(message: msg, traceId: traceId, onRetry: { vm.retry() })
        }
    }
}

// MARK: - Input

private struct CityHallInputContent: View {
    let state: CityHallAuthState.Input
    let vm: CityHallAuthViewModel
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

private struct CityHallScanningContent: View {
    let state: CityHallAuthState.Scanning

    private let allSteps: [ReadEvent] = [
        .connectingToCard, .establishingPace,
        .verifyingPassiveAuth, .verifyingPin,
        .readingIdentity, .verifyingActiveAuth,
    ]

    // In secure/relay mode, server drives steps 3-6 silently — show a pulse after PACE.
    private var showServerProgress: Bool {
        !state.isFastMode && state.completedSteps.contains(.establishingPace)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let msg = state.retryMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            ForEach(Array(allSteps.enumerated()), id: \.offset) { _, step in
                WizardStep(label: step.label, state: stepState(for: step))
            }
            if showServerProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.5))
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private func stepState(for step: ReadEvent) -> StepState {
        if state.completedSteps.contains(where: { $0 == step }) { return .done }
        if state.activeStep == step { return .active }
        return .pending
    }
}

// MARK: - Email Input

private struct CityHallEmailInputContent: View {
    let state: CityHallAuthState.EmailInput
    let vm: CityHallAuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "email_input_hint"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(String(localized: "label_email"), text: Binding(
                get: { state.email },
                set: vm.onEmailChange
            ))
            .keyboardType(.emailAddress)
            .autocapitalization(.none)
            .textContentType(.emailAddress)
            .padding(12)
            .background(Color.white.opacity(0.08))
            .cornerRadius(8)
            .foregroundStyle(Color.white)

            Toggle(String(localized: "email_remember"), isOn: Binding(
                get: { state.remember },
                set: vm.onEmailRememberChange
            ))
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.7))

            Button {
                vm.submitEmail()
            } label: {
                Text(String(localized: "action_continue")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)
            .disabled(state.email.isEmpty)
        }
    }
}

// MARK: - OTP Input

private struct CityHallOtpInputContent: View {
    let state: CityHallAuthState.OtpInput
    let vm: CityHallAuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: String(localized: "otp_hint"), state.email))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            if state.error {
                Text(String(localized: "otp_invalid_error"))
                    .font(.caption)
                    .foregroundStyle(Color.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PinField(
                label: String(localized: "label_otp"),
                maxLength: 6,
                value: Binding(get: { state.code }, set: vm.onOtpChange),
                maskable: false,
                onClear: { vm.onOtpChange("") }
            ) { }

            Button {
                vm.submitOtp()
            } label: {
                Text(String(localized: "action_verify")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)
            .disabled(state.code.count != 6)
        }
    }
}

// MARK: - Success

private struct CityHallSuccessContent: View {
    let name: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.electricBlue)
                .padding(.top, 40)

            Text(name.isEmpty
                ? String(localized: "cityhall_success_message_generic")
                : String(format: String(localized: "cityhall_success_message"), name))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white)

            Button {
                onDone()
            } label: {
                Text(String(localized: "cityhall_success_done")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.electricBlue)
        }
        .padding(.horizontal, 8)
    }
}

