import Foundation
import EidKit

enum AuthState {
    case input(Input)
    case scanning(Scanning)
    case success(Success)
    case error(String)

    struct Input {
        var can: String = ""
        var pin: String = ""
        var canSubmit: Bool { can.count == 6 && pin.count == 4 }

        #if DEBUG
        static let debugDefault = Input(
            can: debugInfoPlistString("DEBUG_NFC_CAN"),
            pin: debugInfoPlistString("DEBUG_NFC_PIN")
        )
        #endif
    }

    struct Scanning {
        var completedSteps: [ReadEvent] = []
        var activeStep: ReadEvent? = nil
        var cardConnected: Bool = false
    }

    struct Success {
        let result: ReadResult
        var saveDialog: SaveDialogState? = nil
    }
}

@MainActor
final class AuthViewModel: ObservableObject {

    #if DEBUG
    @Published var state: AuthState = .input(.debugDefault)
    #else
    @Published var state: AuthState = .input(.init())
    #endif
    private var scanTask: Task<Void, Never>? = nil
    var cancelScan: (() -> Void)?

    private var snapshot: (can: String?, pin: String?, pin2: String?) = (nil, nil, nil)

    // MARK: - Biometric load

    func tryBiometricLoad() async {
        guard BiometricStore.hasCredentials() else { return }
        guard let result = try? await BiometricStore.load() else { return }
        snapshot = result
        guard case .input(var s) = state else { return }
        s.can = result.can ?? s.can
        s.pin = result.pin ?? s.pin
        state = .input(s)
    }

    // MARK: - Input

    func onCanChange(_ v: String) {
        guard case .input(var s) = state else { return }
        s.can = v; state = .input(s)
    }

    func onPinChange(_ v: String) {
        guard case .input(var s) = state else { return }
        s.pin = v; state = .input(s)
    }

    // MARK: - NFC

    func startScan(alertMessage: String) {
        guard case .input(let s) = state, s.canSubmit else { return }
        let savedInput = s
        state = .scanning(.init())
        scanTask?.cancel()
        scanTask = Task {
            do {
                let result = try await EidKitSdk.reader(can: savedInput.can)
                    .withPersonalData(pin: savedInput.pin)
                    .withActiveAuth()
                    .read(
                        alertMessage: alertMessage,
                        cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                        stepMessage: { $0.nfcSheetMessage }
                    ) { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in self.advance(event: event) }
                    }
                let dialog = buildSaveDialog(scannedCan: savedInput.can, scannedPin: savedInput.pin)
                state = .success(.init(result: result, saveDialog: dialog))
            } catch is CancellationError {
                state = .input(savedInput)
            } catch let e as CeiError {
                if case .cardLost = e { state = .input(savedInput) }
                else { state = .error(ceiErrorCode(e)) }
            } catch {
                state = .error(ceiErrorCode(error))
            }
        }
        cancelScan = { [weak self] in self?.scanTask?.cancel() }
    }

    // MARK: - Save dialog

    func onSaveDialogToggle(saveCan: Bool? = nil, savePin: Bool? = nil) {
        guard case .success(var s) = state, s.saveDialog != nil else { return }
        if let v = saveCan { s.saveDialog?.saveCan = v }
        if let v = savePin { s.saveDialog?.savePin = v }
        state = .success(s)
    }

    func dismissSaveDialog() {
        guard case .success(var s) = state else { return }
        s.saveDialog = nil; state = .success(s)
    }

    func neverAskSave() {
        BiometricStore.setNeverAsk()
        dismissSaveDialog()
    }

    func confirmSave() {
        guard case .success(let s) = state, let d = s.saveDialog else { return }
        Task {
            try? await BiometricStore.save(
                can:  .write(d.saveCan ? d.scannedCan : nil),
                pin:  .write(d.savePin ? d.scannedPin : nil),
                pin2: .skip
            )
            snapshot = (
                can:  d.saveCan ? d.scannedCan : nil,
                pin:  d.savePin ? d.scannedPin : nil,
                pin2: snapshot.pin2
            )
            guard case .success(var latest) = state else { return }
            latest.saveDialog = nil
            state = .success(latest)
        }
    }

    func retry() {
        snapshot = (nil, nil, nil)
        state = .input(.init())
    }

    private func advance(event: ReadEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        if event == .connectingToCard { s.cardConnected = true }
        state = .scanning(s)
    }

    private func buildSaveDialog(scannedCan: String, scannedPin: String) -> SaveDialogState? {
        let canChanged = scannedCan != (snapshot.can ?? "")
        let pinChanged = scannedPin != (snapshot.pin ?? "")
        guard canChanged || pinChanged else { return nil }
        return SaveDialogState(
            scannedCan:  scannedCan,
            scannedPin:  scannedPin,
            scannedPin2: "",
            saveCan:     snapshot.can != nil || canChanged,
            savePin:     snapshot.pin != nil || pinChanged,
            savePin2:    false,
            showPin2Row: false
        )
    }
}
