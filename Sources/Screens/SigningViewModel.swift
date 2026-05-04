import Foundation
import EidKit

enum SigningState {
    case documentPicker
    case input(Input)
    case scanning(Scanning)
    case awaitingOutput(AwaitingOutput)
    case success(Success)
    case error(String)

    struct Input {
        let documentName: String
        let padesCtx: PadesContext
        var can: String = ""
        var pin: String = ""
        var canSubmit: Bool { can.count == 6 && pin.count == 6 }
    }

    struct Scanning {
        var completedSteps: [SignEvent] = []
        var activeStep: SignEvent? = nil
        var cardConnected: Bool = false
    }

    struct AwaitingOutput {
        let signedTempUrl: URL
        let signResult: SignResult
        let suggestedFilename: String
    }

    struct Success {
        let outputUrl: URL
        let documentName: String
        let signResult: SignResult
        var saveDialog: SaveDialogState? = nil
    }
}

@MainActor
final class SigningViewModel: ObservableObject {

    @Published var state: SigningState = .documentPicker

    private let pdfSigner = PdfSigner()
    private var snapshot: (can: String?, pin: String?, pin2: String?) = (nil, nil, nil)
    private var pendingSaveDialog: SaveDialogState? = nil

    // MARK: - Biometric load

    func tryBiometricLoad() async {
        guard BiometricStore.hasCredentials() else { return }
        guard let result = try? await BiometricStore.load() else { return }
        snapshot = result
        guard case .input(var s) = state else { return }
        s.can = result.can  ?? s.can
        s.pin = result.pin2 ?? s.pin  // signing screen uses pin2 slot
        state = .input(s)
    }

    // MARK: - Document selection

    func onDocumentSelected(url: URL, displayName: String) {
        let prefix = String(localized: "signing_filename_prefix")
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            switch await pdfSigner.prepare(url: url, displayName: displayName, signedPrefix: prefix) {
            case .success(let ctx):
                var s = SigningState.Input(documentName: displayName, padesCtx: ctx)
                s.can = snapshot.can  ?? ""
                s.pin = snapshot.pin2 ?? ""
                state = .input(s)
            case .failure(let e):
                state = .error("generic:\(e.localizedDescription)")
            }
        }
    }

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
        pendingSaveDialog = buildSaveDialog(scannedCan: savedInput.can, scannedPin2: savedInput.pin)
        state = .scanning(.init())

        Task {
            do {
                let result = try await EidKitSdk.signer(can: savedInput.can)
                    .sign(hash: savedInput.padesCtx.signedAttrsHash, signingPin: savedInput.pin)
                    .execute(
                        alertMessage: alertMessage,
                        cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                        stepMessage: { $0.nfcSheetMessage }
                    ) { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in self.advance(event: event) }
                    }
                let signedTempUrl = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(savedInput.padesCtx.suggestedFilename)
                switch await pdfSigner.complete(ctx: savedInput.padesCtx,
                                                signatureBytes: result.signature,
                                                certificateBytes: result.certificate,
                                                outputUrl: signedTempUrl) {
                case .success:
                    state = .awaitingOutput(.init(
                        signedTempUrl: signedTempUrl,
                        signResult: result,
                        suggestedFilename: savedInput.padesCtx.suggestedFilename
                    ))
                case .failure(let e):
                    state = .error("generic:\(e.localizedDescription)")
                }
            } catch is CancellationError {
                state = .input(savedInput)
            } catch let e as CeiError {
                if case .cardLost = e { state = .input(savedInput) }
                else { state = .error(ceiErrorCode(e)) }
            } catch {
                state = .error(ceiErrorCode(error))
            }
        }
    }

    func onSaveCancelled() {}

    func onOutputUrlSelected(url: URL) {
        guard case .awaitingOutput(let aw) = state else { return }
        state = .success(.init(
            outputUrl: url,
            documentName: aw.suggestedFilename,
            signResult: aw.signResult,
            saveDialog: pendingSaveDialog
        ))
        pendingSaveDialog = nil
    }

    // MARK: - Save dialog

    func onSaveDialogToggle(saveCan: Bool? = nil, savePin2: Bool? = nil) {
        guard case .success(var s) = state, s.saveDialog != nil else { return }
        if let v = saveCan  { s.saveDialog?.saveCan  = v }
        if let v = savePin2 { s.saveDialog?.savePin2 = v }
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
                pin:  .skip,
                pin2: .write(d.savePin2 ? d.scannedPin2 : nil)
            )
            snapshot = (
                can:  d.saveCan  ? d.scannedCan  : nil,
                pin:  snapshot.pin,
                pin2: d.savePin2 ? d.scannedPin2 : nil
            )
            guard case .success(var latest) = state else { return }
            latest.saveDialog = nil
            state = .success(latest)
        }
    }

    func clearDocument() { state = .documentPicker }
    func retry()         { pendingSaveDialog = nil; state = .documentPicker }

    private func advance(event: SignEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        if event == .connectingToCard { s.cardConnected = true }
        state = .scanning(s)
    }

    private func buildSaveDialog(scannedCan: String, scannedPin2: String) -> SaveDialogState? {
        let canChanged  = scannedCan  != (snapshot.can  ?? "")
        let pin2Changed = scannedPin2 != (snapshot.pin2 ?? "")
        guard canChanged || pin2Changed else { return nil }
        return SaveDialogState(
            scannedCan:  scannedCan,
            scannedPin:  "",
            scannedPin2: scannedPin2,
            saveCan:     snapshot.can  != nil || canChanged,
            savePin:     false,
            savePin2:    snapshot.pin2 != nil || pin2Changed,
            showPin2Row: true
        )
    }
}
