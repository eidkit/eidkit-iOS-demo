import Foundation
import EidKit

struct CityHallInput: Identifiable {
    let id = UUID()
    let sessionToken: String
    let callbackUrl: String
    let serviceName: String
    let nonce: String
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

    init(input: CityHallInput) {
        self.input = input
        self.state = .input(.init(
            sessionToken: input.sessionToken,
            callbackUrl: input.callbackUrl,
            serviceName: input.serviceName,
            nonce: input.nonce
        ))
    }

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
                let nonceData: Data? = savedInput.nonce.isEmpty ? nil : hexToData(savedInput.nonce)

                let reader = try EidKitSdk.reader(can: savedInput.can)
                    .withPersonalData(pin: savedInput.pin)

                if let nd = nonceData {
                    reader.withActiveAuth(nonce: nd)
                } else {
                    reader.withActiveAuth()
                }

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

    func retry() {
        state = .input(.init(
            sessionToken: input.sessionToken,
            callbackUrl: input.callbackUrl,
            serviceName: input.serviceName,
            nonce: input.nonce
        ))
    }

    private func advance(event: ReadEvent) {
        guard case .scanning(var s) = state else { return }
        if let prev = s.activeStep { s.completedSteps.append(prev) }
        s.activeStep = event
        state = .scanning(s)
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

        let body: [String: Any] = [
            "sessionToken":              savedInput.sessionToken,
            "cnp":                       cnp,
            "name":                      "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces),
            "givenName":                 firstName,
            "familyName":                lastName,
            "birthdate":                 birthdate,
            "address":                   address,
            "certificate":               dscCertBase64,
            "documentNumber":            documentNumber,
            "documentSeries":            documentSeries,
            "documentExpiry":            documentExpiry,
            "documentIssuer":            documentIssuer,
            "rawDg1":                    rawDg1Base64,
            "sodBytes":                  rawSodBase64,
            "dscCert":                   dscCertBase64,
            "aaChallenge":               savedInput.nonce,
            "aaSignature":               aaSignature,
            "aaCertificate":             aaCertificate,
            "cardSerialNumber":          cardSerial,
            "passedOnDevicePassiveAuth": passedPassive,
            "passedOnDeviceActiveAuth":  passedActive,
        ]

        guard let url = URL(string: savedInput.callbackUrl) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Helpers

    private func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    private func ddmmyyyy_to_iso8601(_ s: String) -> String {
        guard s.count == 8 else { return s }
        let dd = s.prefix(2)
        let mm = s.dropFirst(2).prefix(2)
        let yyyy = s.suffix(4)
        return "\(yyyy)-\(mm)-\(dd)"
    }
}
