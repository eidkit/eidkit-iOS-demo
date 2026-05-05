import Foundation
import LocalAuthentication
import Security

// MARK: - StoreOp

enum StoreOp {
    case write(String?)  // non-nil = store value, nil = delete key
    case skip            // leave key untouched
}

// MARK: - BiometricStore

final class BiometricStore {

    private static let service    = "ro.eidkit.app"
    private static let accountCan = "bio_can"
    private static let accountPin = "bio_pin"
    private static let accountPin2 = "bio_pin2"
    private static let neverAskKey = "bio_never_ask"
    private static let plainPrefs  = UserDefaults.standard

    // MARK: - Never ask

    static func neverAsk() -> Bool {
        plainPrefs.bool(forKey: neverAskKey)
    }

    static func setNeverAsk() {
        plainPrefs.set(true, forKey: neverAskKey)
    }

    // MARK: - Has credentials

    static func hasCredentials() -> Bool {
        // Check without auth context — just see if any item exists
        for account in [accountCan, accountPin, accountPin2] {
            var query: [CFString: Any] = [
                kSecClass:            kSecClassGenericPassword,
                kSecAttrService:      service,
                kSecAttrAccount:      account,
                kSecReturnData:       false,
                kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess || status == errSecInteractionNotAllowed {
                return true
            }
        }
        return false
    }

    // MARK: - Load

    static func load() async throws -> (can: String?, pin: String?, pin2: String?) {
        let context = LAContext()
        let reason  = String(localized: "bio_prompt_title")
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw BiometricError.authFailed
        }
        return (
            can:  readItem(account: accountCan,  context: context),
            pin:  readItem(account: accountPin,  context: context),
            pin2: readItem(account: accountPin2, context: context)
        )
    }

    // MARK: - Save

    static func save(can: StoreOp, pin: StoreOp, pin2: StoreOp) async throws {
        let context = LAContext()
        let reason  = String(localized: "bio_prompt_title")
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw BiometricError.authFailed
        }
        applyOp(op: can,  account: accountCan,  context: context)
        applyOp(op: pin,  account: accountPin,  context: context)
        applyOp(op: pin2, account: accountPin2, context: context)
    }

    // MARK: - Clear

    static func clear() {
        for account in [accountCan, accountPin, accountPin2] {
            let query: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        plainPrefs.removeObject(forKey: neverAskKey)
    }

    // MARK: - Private

    private static func readItem(account: String, context: LAContext) -> String? {
        let query: [CFString: Any] = [
            kSecClass:                  kSecClassGenericPassword,
            kSecAttrService:            service,
            kSecAttrAccount:            account,
            kSecReturnData:             true,
            kSecUseAuthenticationContext: context,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str  = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private static func applyOp(op: StoreOp, account: String, context: LAContext) {
        switch op {
        case .skip: break
        case .write(let value):
            if let value {
                writeItem(value: value, account: account, context: context)
            } else {
                deleteItem(account: account)
            }
        }
    }

    private static func writeItem(value: String, account: String, context: LAContext) {
        guard let data = value.data(using: .utf8) else { return }

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else { return }

        // Try update first
        let searchQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let updateAttrs: [CFString: Any] = [
            kSecValueData:                data,
            kSecAttrAccessControl:        access,
            kSecUseAuthenticationContext: context,
        ]
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus != errSecSuccess {
            // Delete any stale item first, then add fresh with access control
            SecItemDelete(searchQuery as CFDictionary)
            let addQuery: [CFString: Any] = [
                kSecClass:                    kSecClassGenericPassword,
                kSecAttrService:              service,
                kSecAttrAccount:              account,
                kSecValueData:                data,
                kSecAttrAccessControl:        access,
                kSecUseAuthenticationContext: context,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func deleteItem(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum BiometricError: Error {
    case authFailed
}
