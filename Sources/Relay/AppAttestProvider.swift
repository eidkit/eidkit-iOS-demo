import CryptoKit
import DeviceCheck
import Foundation

enum AppAttestError: Error {
    case notSupported
}

actor AppAttestProvider {

    private let service = DCAppAttestService.shared
    private let keyIdKey = "appAttest.keyId"

    func getAssertion(nonce: String) async throws -> (keyId: String, assertion: String) {
        guard service.isSupported else { throw AppAttestError.notSupported }
        let keyId = try await registeredKeyId()
        let hash = Data(SHA256.hash(data: Data(nonce.utf8)))
        let assertionData = try await service.generateAssertion(keyId, clientDataHash: hash)
        return (keyId, assertionData.base64EncodedString())
    }

    private func registeredKeyId() async throws -> String {
        if let stored = UserDefaults.standard.string(forKey: keyIdKey) { return stored }
        let keyId = try await service.generateKey()
        let regHash = Data(SHA256.hash(data: Data("eidkit-registration".utf8)))
        _ = try await service.attestKey(keyId, clientDataHash: regHash)
        UserDefaults.standard.set(keyId, forKey: keyIdKey)
        return keyId
    }
}

func performAttestation(
    provider: AppAttestProvider,
    transport: URLSessionRelayTransport
) async {
    do {
        let raw = try await transport.receiveFrame()
        guard let data = raw.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              frame["type"] as? String == "attest_challenge",
              let nonce = frame["nonce"] as? String
        else {
            print("[Attestation] expected attest_challenge, got: \(raw.prefix(120))")
            return
        }
        print("[Attestation] attest_challenge received, nonce=\(nonce.prefix(16))...")

        let (keyId, assertion) = try await provider.getAssertion(nonce: nonce)
        let response: [String: Any] = [
            "type":      "attest_token",
            "platform":  "ios",
            "keyId":     keyId,
            "assertion": assertion,
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        try transport.sendFrame(json)
        print("[Attestation] attest_token sent, keyId=\(keyId.prefix(16))...")

    } catch is AppAttestError {
        // Simulator or unsupported device — send empty token, server logs and continues
        let response: [String: Any] = ["type": "attest_token", "platform": "ios", "keyId": "", "assertion": ""]
        if let json = try? JSONSerialization.data(withJSONObject: response),
           let str = String(data: json, encoding: .utf8) {
            try? transport.sendFrame(str)
        }
    } catch {
        print("[Attestation] failed: \(error)")
    }
}
