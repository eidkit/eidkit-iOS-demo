import Foundation
import EidKit

enum AuthState {
    case input(Input)
    case scanning(Scanning)
    case success(ReadResult)
    case error(String)

    struct Input {
        var can: String = ""
        var pin: String = ""
        var canSubmit: Bool { can.count == 6 && pin.count == 4 }

        #if DEBUG
        /// Pre-filled for faster local testing. Never compiled into release builds.
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

    func onCanChange(_ v: String) {
        guard case .input(var s) = state else { return }
        s.can = v; state = .input(s)
    }

    func onPinChange(_ v: String) {
        guard case .input(var s) = state else { return }
        s.pin = v; state = .input(s)
    }

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
                state = .success(result)
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

    func retry() {
        state = .input(.init())
    }

    private func advance(event: ReadEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        if event == .connectingToCard { s.cardConnected = true }
        state = .scanning(s)
    }
}
