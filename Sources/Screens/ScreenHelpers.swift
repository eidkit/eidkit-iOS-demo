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

    /// Localized string for the NFC system sheet. Passed to the SDK's `stepMessage:` closure.
    var nfcSheetMessage: String {
        switch self {
        case .connectingToCard:      return String(localized: "nfc_step_connecting",              locale: appLocale)
        case .establishingPace:      return String(localized: "nfc_step_establishing_pace",       locale: appLocale)
        case .readingPhoto:          return String(localized: "nfc_step_reading_photo",           locale: appLocale)
        case .readingSignatureImage: return String(localized: "nfc_step_reading_signature_image", locale: appLocale)
        case .verifyingPassiveAuth:  return String(localized: "nfc_step_verifying_passive_auth",  locale: appLocale)
        case .verifyingPin:          return String(localized: "nfc_step_verifying_pin",           locale: appLocale)
        case .readingIdentity:       return String(localized: "nfc_step_reading_identity",        locale: appLocale)
        case .verifyingActiveAuth:   return String(localized: "nfc_step_verifying_active_auth",   locale: appLocale)
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

    /// Localized string for the NFC system sheet. Passed to the SDK's `stepMessage:` closure.
    var nfcSheetMessage: String {
        switch self {
        case .connectingToCard: return String(localized: "nfc_step_connecting",       locale: appLocale)
        case .establishingPace: return String(localized: "nfc_step_establishing_pace", locale: appLocale)
        case .verifyingPin:     return String(localized: "nfc_step_verifying_pin",     locale: appLocale)
        case .signingDocument:  return String(localized: "nfc_step_signing_document",  locale: appLocale)
        }
    }
}

// MARK: - Card connected warning banner

/// Persistent banner shown in the scanning wizard once the NFC tag is detected.
/// Reinforces the system sheet message for users who glance at the (dimmed) app UI.
struct CardConnectedWarning: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.yellow)
            Text(String(localized: "nfc_card_connected_warning"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }
}
