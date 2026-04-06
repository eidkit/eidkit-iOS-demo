import SwiftUI
import EidKit

// MARK: - App locale

/// Uses Romanian for any non-English system locale (the app ships en + ro only).
var appLocale: Locale {
    let lang = Locale.current.language.languageCode?.identifier ?? "en"
    return Locale(identifier: lang == "en" ? "en" : "ro")
}

// MARK: - Date formatting

func formatDob(_ raw: String) -> String {
    guard raw.count == 8 else { return raw }
    let dd   = raw.prefix(2)
    let mm   = raw.dropFirst(2).prefix(2)
    let yyyy = raw.dropFirst(4)
    return "\(dd)/\(mm)/\(yyyy)"
}

// MARK: - CeiError → error code string

func ceiErrorCode(_ error: Error) -> String {
    guard let e = error as? CeiError else { return "generic:\(error.localizedDescription)" }
    switch e {
    case .wrongPin(let n):   return "wrong_pin:\(n)"
    case .pinBlocked:        return "pin_blocked"
    case .cardLost:          return "card_lost"
    case .paceFailure:       return "pace_failed"
    default:                 return "generic:\(e.localizedDescription)"
    }
}

// MARK: - Error display

struct ErrorContent: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ResultCard(title: localizedError(message), isError: true, onRetry: onRetry) {
            EmptyView()
        }
    }

    private func localizedError(_ code: String) -> String {
        if code.hasPrefix("wrong_pin:") {
            let n = Int(code.dropFirst("wrong_pin:".count)) ?? 0
            return String(format: String(localized: "error_wrong_pin"), n)
        }
        switch code {
        case "pin_blocked":  return String(localized: "error_pin_blocked")
        case "card_lost":    return String(localized: "error_card_lost")
        case "pace_failed":  return String(localized: "error_pace_failed")
        default:
            let msg = code.hasPrefix("generic:") ? String(code.dropFirst("generic:".count)) : code
            return String(format: String(localized: "error_generic"), msg)
        }
    }
}

// MARK: - Event labels

extension ReadEvent {
    var label: String {
        switch self {
        case .connectingToCard:      return String(localized: "step_connecting")
        case .establishingPace:      return String(localized: "step_establishing_pace")
        case .readingPhoto:          return String(localized: "step_reading_photo")
        case .readingSignatureImage: return String(localized: "step_reading_signature_image")
        case .verifyingPassiveAuth:  return String(localized: "step_verifying_passive_auth")
        case .verifyingPin:          return String(localized: "step_verifying_pin")
        case .readingIdentity:       return String(localized: "step_reading_identity")
        case .verifyingActiveAuth:   return String(localized: "step_verifying_active_auth")
        }
    }
}

extension ReadEvent: Equatable {
    public static func == (lhs: ReadEvent, rhs: ReadEvent) -> Bool {
        switch (lhs, rhs) {
        case (.connectingToCard,      .connectingToCard):      return true
        case (.establishingPace,      .establishingPace):      return true
        case (.readingPhoto,          .readingPhoto):          return true
        case (.readingSignatureImage, .readingSignatureImage): return true
        case (.verifyingPassiveAuth,  .verifyingPassiveAuth):  return true
        case (.verifyingPin,          .verifyingPin):          return true
        case (.readingIdentity,       .readingIdentity):       return true
        case (.verifyingActiveAuth,   .verifyingActiveAuth):   return true
        default: return false
        }
    }
}

extension SignEvent {
    var label: String {
        switch self {
        case .connectingToCard: return String(localized: "step_connecting")
        case .establishingPace: return String(localized: "step_establishing_pace")
        case .verifyingPin:     return String(localized: "step_verifying_pin")
        case .signingDocument:  return String(localized: "step_signing_document")
        }
    }
}

extension SignEvent: Equatable {
    public static func == (lhs: SignEvent, rhs: SignEvent) -> Bool {
        switch (lhs, rhs) {
        case (.connectingToCard, .connectingToCard): return true
        case (.establishingPace, .establishingPace): return true
        case (.verifyingPin,     .verifyingPin):     return true
        case (.signingDocument,  .signingDocument):  return true
        default: return false
        }
    }
}
