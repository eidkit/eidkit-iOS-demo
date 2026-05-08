import Foundation
import EidKit
import OpenTelemetryApi

struct CityHallInput: Identifiable {
    let id = UUID()
    let sessionToken: String
    let callbackUrl: String
    let serviceName: String
    let nonce: String
    var traceparent: String? = nil
}

enum CityHallAuthState {
    case input(Input)
    case scanning(Scanning)
    case posting
    case success(String)
    case error(String)

    struct Input {
        var can: String = ""
        var pin: String = ""
        let sessionToken: String
        let callbackUrl: String
        let serviceName: String
        let nonce: String
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
            callbackUrl: input.callbackUrl,
            serviceName: input.serviceName,
            nonce: input.nonce
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
            // If a traceparent was passed from the SSO deep link, create an app-level span
            // as a child of the SSO server transaction. The SDK session span inherits this
            // automatically because EidKit reads the active OTel span at session start.
            let appSpan: (any Span)? = parseTraceparent(input.traceparent).flatMap { spanCtx in
                let tracer = OpenTelemetry.instance.tracerProvider.get(
                    instrumentationName: "eidkit-app", instrumentationVersion: nil)
                let span = tracer.spanBuilder(spanName: "remote_auth")
                    .setSpanKind(spanKind: .internal)
                    .setRemoteParent(spanCtx)
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
                let nonceData: Data? = savedInput.nonce.isEmpty ? nil : hexToData(savedInput.nonce)
                let reader = try EidKitSdk.reader(can: savedInput.can)
                    .withPersonalData(pin: savedInput.pin)
                    .withChipAuth()
                if let nd = nonceData { reader.withActiveAuth(nonce: nd) }
                else { reader.withActiveAuth() }

                let result = try await reader.read(
                    alertMessage: alertMessage,
                    cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                    stepMessage: { $0.nfcSheetMessage }
                ) { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in self.advance(event: event) }
                }

                state = .posting
                try await postSessionComplete(result: result, savedInput: savedInput)
                let firstName = result.identity?.firstName ?? ""
                let lastName  = result.identity?.lastName ?? ""
                let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)

                let dialog = buildSaveDialog(scannedCan: savedInput.can, scannedPin: savedInput.pin)
                saveDialog = dialog
                state = .success(name)

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
            callbackUrl: input.callbackUrl,
            serviceName: input.serviceName,
            nonce: input.nonce
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

    // MARK: - Webhook POST

    private func postSessionComplete(result: ReadResult, savedInput: CityHallAuthState.Input) async throws {
        let identity = result.identity
        let personalData = result.personalData
        let claim = result.claim
        let proof = claim?.passiveAuthProof
        let aaProof = claim?.activeAuthProof

        let firstName      = identity?.firstName ?? ""
        let lastName       = identity?.lastName ?? ""
        let cnp            = identity?.cnp ?? ""
        let birthdate      = ddmmyyyy_to_iso8601(identity?.dateOfBirth ?? "")
        let address        = personalData?.address ?? ""
        let documentIssuer = personalData?.issuingAuthority ?? ""
        let documentExpiry = ddmmyyyy_to_iso8601(personalData?.expiryDate ?? "")
        let rawDocNumber   = personalData?.documentNumber ?? ""
        let splitAt        = rawDocNumber.firstIndex(where: { $0.isNumber }) ?? rawDocNumber.startIndex
        let documentSeries = String(rawDocNumber[..<splitAt])
        let documentNumber = String(rawDocNumber[splitAt...])
        let passedPassive  = { if case .valid = result.passiveAuth { return true }; return false }()
        let passedActive   = { if case .verified = result.activeAuth { return true }; return false }()
        let dscCertBase64  = proof?.docSigningCert.base64EncodedString() ?? ""
        let rawSodBase64   = proof?.sodBytes.base64EncodedString() ?? ""
        let rawDg1Base64   = claim?.rawDg1?.base64EncodedString() ?? ""
        let aaSignature    = aaProof?.signature.base64EncodedString() ?? ""
        let aaCertificate  = aaProof?.certificate.base64EncodedString() ?? ""
        let cardSerial     = claim?.cardSerialNumber ?? ""
        let caProof               = claim?.chipAuthProof
        let caTerminalPublicKey   = caProof?.terminalPublicKey.base64EncodedString() ?? ""
        let caEphemeralPrivateKey = caProof?.ephemeralPrivateKey.base64EncodedString() ?? ""
        let caSharedSecretX       = caProof?.sharedSecretX.base64EncodedString() ?? ""
        let rawDg14Base64         = caProof?.rawDg14.base64EncodedString() ?? ""

        let body: [String: Any] = [
            "sessionToken": savedInput.sessionToken,
            "cnp": cnp, "name": "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces),
            "givenName": firstName, "familyName": lastName, "birthdate": birthdate,
            "address": address, "certificate": dscCertBase64,
            "documentNumber": documentNumber, "documentSeries": documentSeries,
            "documentExpiry": documentExpiry, "documentIssuer": documentIssuer,
            "rawDg1": rawDg1Base64, "sodBytes": rawSodBase64, "dscCert": dscCertBase64,
            "aaChallenge": savedInput.nonce, "aaSignature": aaSignature,
            "aaCertificate": aaCertificate, "cardSerialNumber": cardSerial,
            "passedOnDevicePassiveAuth": passedPassive, "passedOnDeviceActiveAuth": passedActive,
            "caTerminalPublicKey": caTerminalPublicKey, "caEphemeralPrivateKey": caEphemeralPrivateKey,
            "caSharedSecretX": caSharedSecretX, "rawDg14": rawDg14Base64,
        ]
        guard let url = URL(string: savedInput.callbackUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let span = OpenTelemetry.instance.contextProvider.activeSpan {
            let sc = span.context
            let traceId = sc.traceId.hexString
            let spanId  = sc.spanId.hexString
            let sampled = sc.traceFlags.sampled
            let flagsHex = sampled ? "01" : "00"
            request.setValue("00-\(traceId)-\(spanId)-\(flagsHex)", forHTTPHeaderField: "traceparent")
            request.setValue("\(traceId)-\(spanId)-\(sampled ? "1" : "0")", forHTTPHeaderField: "sentry-trace")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
    }

    private func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte); idx = next
        }
        return data
    }

    private func ddmmyyyy_to_iso8601(_ s: String) -> String {
        guard s.count == 8 else { return s }
        return "\(s.suffix(4))-\(s.dropFirst(2).prefix(2))-\(s.prefix(2))"
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
