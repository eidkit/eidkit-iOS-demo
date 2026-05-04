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
        case .input(let s):    CityHallInputContent(state: s, vm: vm)
        case .scanning(let s): CityHallScanningContent(state: s)
        case .posting:         CityHallPostingContent()
        case .success(let name): CityHallSuccessContent(name: name, onDone: onDismiss)
        case .error(let msg):  ErrorContent(message: msg, onRetry: { vm.retry() })
        }
    }
}

// MARK: - Input

private struct CityHallInputContent: View {
    let state: CityHallAuthState.Input
    let vm: CityHallAuthViewModel
    @FocusState private var focus: Field?
    @State private var hasCredentials = BiometricStore.hasCredentials()
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
}

// MARK: - Scanning

private struct CityHallScanningContent: View {
    let state: CityHallAuthState.Scanning

    private let allSteps: [ReadEvent] = [
        .connectingToCard, .establishingPace,
        .verifyingPassiveAuth, .verifyingPin,
        .readingIdentity, .verifyingActiveAuth,
    ]

    var body: some View {
        VStack(spacing: 10) {
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

private struct CityHallSuccessContent: View {
    let name: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.electricBlue)
                .padding(.top, 40)

            Text(String(format: String(localized: "cityhall_success_message"), name))
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

// MARK: - Posting

private struct CityHallPostingContent: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
            Text(String(localized: "cityhall_posting"))
                .foregroundStyle(Color.white.opacity(0.7))
                .font(.caption)
        }
        .padding(.top, 40)
    }
}
