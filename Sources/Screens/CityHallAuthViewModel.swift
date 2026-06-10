import Foundation
import EidKit
import OpenTelemetryApi

struct CityHallInput: Identifiable {
    let id = UUID()
    let sessionToken: String
    let wsUrl: URL
    let serviceName: String
    var traceparent: String? = nil
    var mode: String = "secure"

    var isFastMode: Bool { mode == "fast" }

    var httpBaseUrl: URL {
        let wsStr = wsUrl.absoluteString
        let base = wsStr.components(separatedBy: "/v3/nfc-relay").first ?? wsStr
        return URL(string: base
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://"))!
    }
}

enum CityHallAuthState {
    case input(Input)
    case scanning(Scanning)
    case emailInput(EmailInput)
    case otpInput(OtpInput)
    case success(String)
    case error(String, traceId: String?)

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
        var retryMessage: String? = nil
        var isFastMode: Bool = false
    }

    struct EmailInput {
        let prefill: String?
        let clientId: String
        var email: String
        var remember: Bool = false
        init(prefill: String?, clientId: String = "") {
            self.prefill = prefill; self.clientId = clientId; self.email = prefill ?? ""
        }
    }

    struct OtpInput {
        let email: String
        let clientId: String
        var code: String = ""
        var remember: Bool = false
        var error: Bool = false
        init(email: String, clientId: String = "") { self.email = email; self.clientId = clientId }
    }
}

@MainActor
final class CityHallAuthViewModel: ObservableObject {

    @Published var state: CityHallAuthState
    private var scanTask: Task<Void, Never>? = nil
    private let input: CityHallInput
    var cancelScan: (() -> Void)?
    var onSuccess: (() -> Void)?

    private var activeTransport: URLSessionRelayTransport?
    // Fast mode: retained for email/OTP HTTP calls after card read completes
    private var fastSessionToken: String? = nil

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
        state = .scanning(.init(isFastMode: input.isFastMode))
        scanTask?.cancel()
        scanTask = Task {
            let tracer = OpenTelemetry.instance.tracerProvider.get(
                instrumentationName: "eidkit-app", instrumentationVersion: nil)
            let spanBuilder = tracer.spanBuilder(spanName: "remote_auth")
                .setSpanKind(spanKind: .internal)
            if let spanCtx = parseTraceparent(input.traceparent) {
                spanBuilder.setParent(spanCtx)
            }
            let appSpan = spanBuilder.startSpan()
            OpenTelemetry.instance.contextProvider.setActiveSpan(appSpan)
            defer {
                appSpan.end()
                OpenTelemetry.instance.contextProvider.removeContextForSpan(appSpan)
            }
            let maxRetries = 2
            var retryCount = 0
            var succeeded = false

            while !succeeded {
                do {
                    if input.isFastMode {
                        try await runFastSession(
                            alertMessage: retryCount == 0 ? alertMessage : String(localized: "nfc_alert_retry", locale: appLocale),
                            can: savedInput.can,
                            pin: savedInput.pin,
                            retryCount: retryCount
                        )
                    } else {
                        let transport = URLSessionRelayTransport()
                        activeTransport = transport
                        let attester = AppAttestProvider()
                        try await transport.connectForAttestation(url: savedInput.wsUrl)
                        await performAttestation(provider: attester, transport: transport)
                        try await EidKitSdk.relay(
                            alertMessage: retryCount == 0 ? alertMessage : String(localized: "nfc_alert_retry", locale: appLocale),
                            cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                            can: savedInput.can,
                            pin: savedInput.pin,
                            wsUrl: savedInput.wsUrl,
                            transport: transport,
                            onEvent: { [weak self] event in
                                Task { @MainActor [weak self] in self?.advance(event: event) }
                            },
                            onUnknownFrame: { [weak self] type, frame in
                                Task { @MainActor [weak self] in self?.handleRelayFrame(type: type, frame: frame) }
                            }
                        )
                        activeTransport = nil
                    }

                    // Fast mode email: runFastSession sets state to emailInput/otpInput and returns —
                    // success is emitted later by submitFastEmail/submitFastOtp. Don't overwrite here.
                    // In secure relay mode, relay() only returns after done — always go to success.
                    if input.isFastMode {
                        if case .emailInput(_) = state { succeeded = true; break }
                        if case .otpInput(_) = state   { succeeded = true; break }
                    }
                    let dialog = buildSaveDialog(scannedCan: savedInput.can, scannedPin: savedInput.pin)
                    saveDialog = dialog
                    state = .success("")
                    succeeded = true

                } catch is CancellationError {
                    activeTransport = nil
                    state = .input(savedInput)
                    return
                } catch CeiError.cardLost {
                    activeTransport = nil
                    if retryCount < maxRetries {
                        retryCount += 1
                        state = .scanning(.init(retryMessage: String(localized: "nfc_card_lost_retry"), isFastMode: input.isFastMode))
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    } else {
                        state = .input(savedInput)
                        return
                    }
                } catch CeiError.paceFailure {
                    activeTransport = nil
                    // Only retry on first attempt — could be card moved during tap.
                    // On retry, more likely wrong CAN — go to error.
                    if retryCount == 0 {
                        retryCount += 1
                        state = .scanning(.init(retryMessage: String(localized: "nfc_card_lost_retry"), isFastMode: input.isFastMode))
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    } else {
                        state = .input(savedInput)
                        return
                    }
                } catch let e as CeiError {
                    activeTransport = nil
                    let traceId = appSpan.context.traceId.hexString
                    switch e {
                    case .wrongPin(let r): state = .error("wrong_pin:\(r)", traceId: traceId)
                    case .pinBlocked:      state = .error("pin_blocked", traceId: traceId)
                    default:               state = .error("card_error:\(e)", traceId: traceId)
                    }
                    return
                } catch {
                    activeTransport = nil
                    let traceId = appSpan.context.traceId.hexString
                    state = .error("network:\(error.localizedDescription)", traceId: traceId)
                    return
                }
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

    func onEmailChange(_ v: String) {
        guard case .emailInput(var s) = state else { return }
        s.email = v; state = .emailInput(s)
    }

    func onEmailRememberChange(_ v: Bool) {
        guard case .emailInput(var s) = state else { return }
        s.remember = v; state = .emailInput(s)
    }

    func submitEmail() {
        if fastSessionToken != nil { Task { await submitFastEmail() }; return }
        guard case .emailInput(let s) = state, !s.email.isEmpty else { return }
        // If email matches the verified prefill, server skips OTP — save now since submitOtp won't be reached.
        if s.remember, !s.clientId.isEmpty, let prefill = s.prefill, s.email.lowercased() == prefill.lowercased() {
            EmailStore.remember(clientId: s.clientId, serviceName: input.serviceName, email: s.email)
        }
        var otp = CityHallAuthState.OtpInput(email: s.email, clientId: s.clientId)
        otp.remember = s.remember
        state = .otpInput(otp)
        try? activeTransport?.sendFrame(makeJson(["type": "email_submit", "email": s.email]))
    }

    func onOtpChange(_ v: String) {
        guard case .otpInput(var s) = state else { return }
        s.code = v; s.error = false; state = .otpInput(s)
    }

    func onOtpRememberChange(_ v: Bool) {
        guard case .otpInput(var s) = state else { return }
        s.remember = v; state = .otpInput(s)
    }

    func submitOtp() {
        if fastSessionToken != nil { Task { await submitFastOtp() }; return }
        guard case .otpInput(let s) = state, s.code.count == 6 else { return }
        if s.remember && !s.clientId.isEmpty {
            EmailStore.remember(clientId: s.clientId, serviceName: input.serviceName, email: s.email)
        }
        try? activeTransport?.sendFrame(makeJson(["type": "email_otp", "code": s.code, "remember": s.remember]))
    }

    private func handleRelayFrame(type: String, frame: [String: Any]) {
        switch type {
        case "email_request":
            let prefill  = frame["prefill"]   as? String
            let clientId = frame["client_id"] as? String ?? ""
            // If a remembered email exists for this client, silently resubmit it.
            // Still set emailInput state so that if the server requires OTP (e.g. DB has
            // a different email from another device), the OTP screen shows the right address.
            let remembered = clientId.isEmpty ? nil : EmailStore.getRemembered(clientId: clientId)
            let autoSubmit = remembered != nil && (prefill == nil || remembered!.lowercased() == prefill!.lowercased())
            if autoSubmit {
                state = .emailInput(.init(prefill: remembered, clientId: clientId))
                try? activeTransport?.sendFrame(makeJson(["type": "email_submit", "email": remembered!]))
            } else {
                state = .emailInput(.init(prefill: prefill, clientId: clientId))
            }
        case "email_otp_sent":
            let email: String; let clientId: String; let remember: Bool
            if case .emailInput(let s) = state { email = s.email; clientId = s.clientId; remember = s.remember }
            else if case .otpInput(let s) = state { email = s.email; clientId = s.clientId; remember = s.remember }
            else { email = ""; clientId = ""; remember = false }
            var otp = CityHallAuthState.OtpInput(email: email, clientId: clientId)
            otp.remember = remember
            state = .otpInput(otp)
        case "email_otp_invalid":
            guard case .otpInput(var s) = state else { break }
            s.code = ""
            s.error = true
            state = .otpInput(s)
        default: break
        }
    }

    private func makeJson(_ dict: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    func retry() {
        state = .input(.init(
            sessionToken: input.sessionToken,
            wsUrl: input.wsUrl,
            serviceName: input.serviceName
        ))
    }

    // MARK: - Fast mode email / OTP (HTTP, no WebSocket)

    private func submitFastEmail() async {
        guard case .emailInput(let s) = state, !s.email.isEmpty,
              let sessionToken = fastSessionToken else { return }
        let url = input.httpBaseUrl.appendingPathComponent("v3/local-auth/email")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": sessionToken, "email": s.email])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            state = .error("fast_email_network", traceId: nil); return
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "email_submit_failed"
            state = .error(msg, traceId: nil); return
        }
        if let status = json["status"] as? String, status == "otp_sent" {
            var otp = CityHallAuthState.OtpInput(email: s.email, clientId: s.clientId)
            otp.remember = s.remember
            state = .otpInput(otp)
        } else if json["code"] != nil {
            // Prefill reused — OTP skipped — save email now since submitFastOtp won't be called
            if s.remember && !s.clientId.isEmpty {
                EmailStore.remember(clientId: s.clientId, serviceName: input.serviceName, email: s.email)
            }
            fastSessionToken = nil
            saveDialog = buildSaveDialog(scannedCan: "", scannedPin: "")
            state = .success("")
        } else {
            state = .error("fast_email_unexpected", traceId: nil)
        }
    }

    private func submitFastOtp() async {
        guard case .otpInput(let s) = state, s.code.count == 6,
              let sessionToken = fastSessionToken else { return }
        if s.remember && !s.clientId.isEmpty {
            EmailStore.remember(clientId: s.clientId, serviceName: input.serviceName, email: s.email)
        }
        let url = input.httpBaseUrl.appendingPathComponent("v3/local-auth/otp")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": sessionToken, "code": s.code])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            state = .error("fast_otp_network", traceId: nil); return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            state = .error("fast_otp_parse_error", traceId: nil); return
        }
        if http.statusCode == 200, json["code"] != nil {
            fastSessionToken = nil
            saveDialog = buildSaveDialog(scannedCan: "", scannedPin: "")
            state = .success("")
        } else if let status = json["status"] as? String, status == "otp_invalid" {
            var updated = s; updated.error = true; updated.code = ""
            state = .otpInput(updated)
        } else {
            state = .error("otp_failed:\(http.statusCode)", traceId: nil)
        }
    }

    // MARK: - Fast local mode

    private func runFastSession(alertMessage: String, can: String, pin: String, retryCount: Int = 0) async throws {
        // 1. Fetch AA challenge from server
        var challengeUrl = URLComponents(url: input.httpBaseUrl.appendingPathComponent("v3/session/challenge"), resolvingAgainstBaseURL: false)!
        challengeUrl.queryItems = [URLQueryItem(name: "session", value: input.sessionToken)]
        let (challengeData, _) = try await URLSession.shared.data(from: challengeUrl.url!)
        guard let challengeJson = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              let aaHex = challengeJson["aa_challenge"] as? String else {
            throw NSError(domain: "EidKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "challenge_missing"])
        }
        // Convert hex string to Data
        let aaChallenge = Data(stride(from: 0, to: aaHex.count, by: 2).compactMap {
            UInt8(aaHex[aaHex.index(aaHex.startIndex, offsetBy: $0) ..< aaHex.index(aaHex.startIndex, offsetBy: $0 + 2)], radix: 16)
        })

        // 2. Read card locally with step-by-step progress
        let result = try await EidKitSdk.reader(can: can)
            .withPersonalData(pin: pin)
            .withActiveAuth(nonce: aaChallenge)
            .read(
                alertMessage: alertMessage,
                cardConnectedMessage: String(localized: "nfc_card_connected_warning", locale: appLocale),
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in self?.advance(event: event) }
                }
            )
        guard let claim = result.claim else {
            throw NSError(domain: "EidKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "claim_missing"])
        }
        guard let activeProof = claim.activeAuthProof else {
            throw NSError(domain: "EidKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "aa_proof_missing"])
        }

        // 3. POST claim to /v3/local-auth
        let id = claim.identity
        let pd = claim.personalData
        var body: [String: Any] = [
            "session":          input.sessionToken,
            "sod":              claim.passiveAuthProof.sodBytes.base64EncodedString(),
            "doc_signing_cert": claim.passiveAuthProof.docSigningCert.base64EncodedString(),
            "csca_cert":        claim.passiveAuthProof.cscaCert.base64EncodedString(),
            "aa_challenge":     activeProof.challenge.base64EncodedString(),
            "aa_signature":     activeProof.signature.base64EncodedString(),
            "aa_cert":          activeProof.certificate.base64EncodedString(),
            "platform":         "ios",
            "last_name":        id.lastName,
            "first_name":       id.firstName,
            "date_of_birth":    id.dateOfBirth,
            "cnp":              id.cnp,
        ]
        if let dg1 = claim.rawDg1           { body["raw_dg1"]           = dg1.base64EncodedString() }
        if let v = pd?.documentNumber       { body["document_number"]    = v }
        if let v = pd?.issueDate            { body["issue_date"]         = v }
        if let v = pd?.expiryDate           { body["expiry_date"]        = v }
        if let v = pd?.issuingAuthority     { body["issuing_authority"]  = v }
        if let v = pd?.address              { body["address"]            = v }
        if retryCount > 0 { body["retry_count"] = retryCount }

        let postUrl = input.httpBaseUrl.appendingPathComponent("v3/local-auth")
        var request = URLRequest(url: postUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (respData, httpResp) = try await URLSession.shared.data(for: request)
        guard let http = httpResp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? String ?? "local_auth_failed"
            throw NSError(domain: "EidKit", code: 4, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else { return }
        if let status = json["status"] as? String, status == "email_required" {
            fastSessionToken = input.sessionToken
            let prefill  = json["prefill"]   as? String
            let clientId = json["client_id"] as? String ?? ""
            let remembered = clientId.isEmpty ? nil : EmailStore.getRemembered(clientId: clientId)
            let autoSubmit = remembered != nil && (prefill == nil || remembered!.lowercased() == prefill!.lowercased())
            if autoSubmit {
                state = .emailInput(.init(prefill: remembered, clientId: clientId))
                await submitFastEmail()
            } else {
                state = .emailInput(.init(prefill: prefill, clientId: clientId))
            }
            // Don't throw — caller will see state is emailInput and skip Success transition
        }
        // If status is absent or "code" is present, caller handles success normally
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
