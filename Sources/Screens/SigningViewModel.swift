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
    }

    struct AwaitingOutput {
        let padesCtx: PadesContext
        let signResult: SignResult
        let suggestedFilename: String
    }

    struct Success {
        let outputUrl: URL
        let documentName: String
        let signResult: SignResult
    }
}

@MainActor
final class SigningViewModel: ObservableObject {

    @Published var state: SigningState = .documentPicker
    @Published var pendingFileSave = false

    private let pdfSigner = PdfSigner()

    func onDocumentSelected(url: URL, displayName: String) {
        let prefix = String(localized: "signing_filename_prefix")
        Task {
            // fileImporter provides a security-scoped URL — must unlock before reading.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            switch await pdfSigner.prepare(url: url, displayName: displayName, signedPrefix: prefix) {
            case .success(let ctx):
                state = .input(.init(documentName: displayName, padesCtx: ctx))
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

    func startScan() {
        guard case .input(let s) = state, s.canSubmit else { return }
        state = .scanning(.init())

        Task {
            do {
                let result = try await EidKitSdk.signer(can: s.can)
                    .sign(hash: s.padesCtx.signedAttrsHash, signingPin: s.pin)
                    .execute { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in self.advance(event: event) }
                    }
                state = .awaitingOutput(.init(
                    padesCtx: s.padesCtx,
                    signResult: result,
                    suggestedFilename: s.padesCtx.suggestedFilename
                ))
                pendingFileSave = true
            } catch {
                state = .error(ceiErrorCode(error))
            }
        }
    }

    func onOutputUrlSelected(url: URL) {
        guard case .awaitingOutput(let aw) = state else { return }
        Task {
            switch await pdfSigner.complete(ctx: aw.padesCtx,
                                            signatureBytes: aw.signResult.signature,
                                            certificateBytes: aw.signResult.certificate,
                                            outputUrl: url) {
            case .success:
                state = .success(.init(outputUrl: url,
                                       documentName: aw.padesCtx.suggestedFilename,
                                       signResult: aw.signResult))
            case .failure(let e):
                state = .error("generic:\(e.localizedDescription)")
            }
        }
    }

    func clearDocument() { state = .documentPicker }
    func retry()         { state = .documentPicker }

    private func advance(event: SignEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        state = .scanning(s)
    }
}
