import Foundation
import EidKit
import OpenTelemetryApi

struct CityHallInput: Identifiable {
    let id = UUID()
    let sessionToken: String
    let wsUrl: URL
    let serviceName: String
    var traceparent: String? = nil
}

enum CityHallAuthState {
    case input(Input)
    case scanning(Scanning)
    case success(String)
    case error(String)

    struct Input {
        var can: String = ""
        var pin: String = ""
        let sessionToken: String
        let wsUrl: URL
        let serviceName: String
        var canSubmit: Bool { can.count == 6 && pin.count == 4 }
    }

    struct Scanning {
        var completedSteps: [ReadEvent] = []
        var activeStep: ReadEvent? = nil
    }
}

@MainActor
final class CityHallAuthViewModel: ObservableObject {

    @Published var state: CityHallAuthState
    private var scanTask: Task<Void, Never>? = nil
    private let input: CityHallInput
    var cancelScan: (() -> Void)?
    var onSuccess: (() -> Void)?

    private var snapshot: (can: String?, pin: String?, pin2: String?) = (nil, nil, nil)
    @Published var saveDialog: SaveDialogState? = nil

    init(input: CityHallInput) {
        self.input = input
        self.state = .input(.init(
            sessionToken: input.sessionToken,
            wsUrl: input.wsUrl,
            serviceName: input.serviceName
        ))
    }

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
            let appSpan: (any Span)? = parseTraceparent(input.traceparent).flatMap { spanCtx in
                let tracer = OpenTelemetry.instance.tracerProvider.get(
                    instrumentationName: "eidkit-app", instrumentationVersion: nil)
                let span = tracer.spanBuilder(spanName: "remote_auth")
                    .setSpanKind(spanKind: .internal)
                    .setParent(spanCtx)
                    .startSpan()
                OpenTelemetry.instance.contextProvider.setActiveSpan(span)
                return span
            }
            defer {
                if let s = appSpan {
                    s.end()
                    OpenTelemetry.instance.contextProvider.removeContextForSpan(s)
                }
            }
            do {
                let transport = URLSessionRelayTransport()
                let attester = AppAttestProvider()
                try await transport.connectForAttestation(url: savedInput.wsUrl)
                await performAttestation(provider: attester, transport: transport)
                try await EidKitSdk.relay(
                    alertMessage: alertMessage,
                    cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                    can: savedInput.can,
                    pin: savedInput.pin,
                    wsUrl: savedInput.wsUrl,
                    transport: transport
                ) { [weak self] event in
                    Task { @MainActor [weak self] in self?.advance(event: event) }
                }

                let dialog = buildSaveDialog(scannedCan: savedInput.can, scannedPin: savedInput.pin)
                saveDialog = dialog
                state = .success("")

            } catch is CancellationError {
                state = .input(savedInput)
            } catch let e as CeiError {
                switch e {
                case .cardLost:        state = .input(savedInput)
                case .wrongPin(let r): state = .error("wrong_pin:\(r)")
                case .pinBlocked:      state = .error("pin_blocked")
                case .paceFailure:     state = .error("pace_failed")
                default:               state = .error("card_error:\(e)")
                }
            } catch {
                state = .error("network:\(error.localizedDescription)")
            }
        }
        cancelScan = { [weak self] in self?.scanTask?.cancel() }
    }

    // MARK: - Save dialog

    func onSaveDialogToggle(saveCan: Bool? = nil, savePin: Bool? = nil) {
        if let v = saveCan { saveDialog?.saveCan = v }
        if let v = savePin { saveDialog?.savePin = v }
    }

    func dismissSaveDialog() {
        saveDialog = nil
    }

    func neverAskSave() {
        BiometricStore.setNeverAsk()
        saveDialog = nil
    }

    func confirmSave() {
        guard let d = saveDialog else { return }
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
            saveDialog = nil
        }
    }

    func retry() {
        state = .input(.init(
            sessionToken: input.sessionToken,
            wsUrl: input.wsUrl,
            serviceName: input.serviceName
        ))
    }

    // MARK: - Private

    private func advance(event: ReadEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
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

// Parses a W3C traceparent header value into an OTel SpanContext.
// Format: 00-<traceId:32hex>-<spanId:16hex>-<flags:2hex>
private func parseTraceparent(_ traceparent: String?) -> SpanContext? {
    guard let tp = traceparent else { return nil }
    let parts = tp.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 4,
          parts[0] == "00",
          parts[1].count == 32,
          parts[2].count == 16,
          let flags = UInt8(parts[3], radix: 16) else { return nil }
    let traceId = TraceId(fromHexString: String(parts[1]))
    let spanId  = SpanId(fromHexString: String(parts[2]))
    guard traceId.isValid, spanId.isValid else { return nil }
    return SpanContext.createFromRemoteParent(
        traceId: traceId,
        spanId: spanId,
        traceFlags: TraceFlags(fromByte: flags),
        traceState: TraceState()
    )
}
