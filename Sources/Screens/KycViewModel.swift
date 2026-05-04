import Foundation
import EidKit

// MARK: - State

enum ExportState {
    case idle
    case exporting
    case done(url: URL)
    case failed(String)
}

enum KycState {
    case input(Input)
    case scanning(Scanning)
    case success(Success)
    case error(String)

    struct Input {
        var can: String = ""
        var pin: String = ""
        var includePhoto: Bool = false
        var includeSignature: Bool = false
        var canSubmit: Bool { can.count == 6 && pin.count == 4 }
    }

    struct Scanning {
        var completedSteps: [ReadEvent] = []
        var activeStep: ReadEvent? = nil
        var cardConnected: Bool = false
        var includePhoto: Bool
        var includeSignature: Bool
    }

    struct Success {
        let result: ReadResult
        var exportState: ExportState = .idle
        var saveDialog: SaveDialogState? = nil
    }
}

// MARK: - ViewModel

@MainActor
final class KycViewModel: ObservableObject {

    @Published var state: KycState = .input(.init())
    private let pdfGenerator = KycPdfGenerator()
    private var scanTask: Task<Void, Never>? = nil
    var cancelScan: (() -> Void)?

    // What was in the store when this screen opened
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

    func onPhotoToggle(_ v: Bool) {
        guard case .input(var s) = state else { return }
        s.includePhoto = v; state = .input(s)
    }

    func onSignatureToggle(_ v: Bool) {
        guard case .input(var s) = state else { return }
        s.includeSignature = v; state = .input(s)
    }

    // MARK: - NFC

    func startScan(alertMessage: String) {
        guard case .input(let s) = state, s.canSubmit else { return }
        let savedInput = s
        state = .scanning(.init(includePhoto: s.includePhoto, includeSignature: s.includeSignature))
        scanTask?.cancel()
        scanTask = Task {
            do {
                let result = try await EidKitSdk.reader(can: savedInput.can)
                    .withPersonalData(pin: savedInput.pin)
                    .withActiveAuth()
                    .withPhoto(savedInput.includePhoto)
                    .withSignatureImage(savedInput.includeSignature)
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
                can:  .write(d.saveCan  ? d.scannedCan  : nil),
                pin:  .write(d.savePin  ? d.scannedPin  : nil),
                pin2: .skip
            )
            snapshot = (
                can:  d.saveCan  ? d.scannedCan  : nil,
                pin:  d.savePin  ? d.scannedPin  : nil,
                pin2: snapshot.pin2
            )
            guard case .success(var latest) = state else { return }
            latest.saveDialog = nil
            state = .success(latest)
        }
    }

    // MARK: - Export

    func exportToPdf() {
        guard case .success(var s) = state else { return }
        guard case .idle = s.exportState else { return }
        s.exportState = .exporting
        state = .success(s)

        Task {
            guard case .success(let current) = state else { return }
            let result = await pdfGenerator.generate(current.result)
            guard case .success(var latest) = state else { return }
            switch result {
            case .success(let url): latest.exportState = .done(url: url)
            case .failure(let e):   latest.exportState = .failed(e.localizedDescription)
            }
            state = .success(latest)
        }
    }

    func retry() {
        snapshot = (nil, nil, nil)
        state = .input(.init())
    }

    // MARK: - Private

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
