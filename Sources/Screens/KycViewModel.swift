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
        var includePhoto: Bool
        var includeSignature: Bool
    }

    struct Success {
        let result: ReadResult
        var exportState: ExportState = .idle
    }
}

// MARK: - ViewModel

@MainActor
final class KycViewModel: ObservableObject {

    @Published var state: KycState = .input(.init())
    private let pdfGenerator = KycPdfGenerator()
    private var scanTask: Task<Void, Never>? = nil
    var cancelScan: (() -> Void)?

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
                    .read(alertMessage: alertMessage) { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in self.advance(event: event) }
                    }
                state = .success(.init(result: result))
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
        state = .input(.init())
    }

    // MARK: - Private

    private func advance(event: ReadEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        state = .scanning(s)
    }
}
