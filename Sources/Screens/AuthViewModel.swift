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
    }

    struct Scanning {
        var completedSteps: [ReadEvent] = []
        var activeStep: ReadEvent? = nil
    }
}

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var state: AuthState = .input(.init())
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

    func startScan() {
        guard case .input(let s) = state, s.canSubmit else { return }
        state = .scanning(.init())
        scanTask?.cancel()
        scanTask = Task {
            do {
                let result = try await EidKit.reader(can: s.can)
                    .withPersonalData(pin: s.pin)
                    .withActiveAuth()
                    .read { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in self.advance(event: event) }
                    }
                state = .success(result)
            } catch is CancellationError {
                // Scan cancelled, revert to input
                state = .input(.init())
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
        state = .scanning(s)
    }
}
