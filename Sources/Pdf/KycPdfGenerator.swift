import Foundation
import PDFKit
import UIKit
import EidKit

/// Generates an A4 KYC identity report PDF from a `ReadResult`.
/// Mirrors the Android `KycPdfGenerator` layout — header bar, identity table, auth status, signature image.
/// Uses PDFKit + Core Graphics (no external dependency).
final class KycPdfGenerator {

    func generate(_ result: ReadResult) async -> Result<URL, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try self.buildAndSave(result) }
        }.value
    }

    // MARK: - Build

    private func buildAndSave(_ result: ReadResult) throws -> URL {
        let cnp = result.identity?.cnp ?? "unknown"
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let filename = "KYC_\(cnp)_\(ts).pdf"

        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4 points
        let margin: CGFloat = 40
        let contentWidth = pageRect.width - 2 * margin

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let cgCtx = ctx.cgContext
            var y: CGFloat = pageRect.height - margin

            // ── Header bar ──────────────────────────────────────────────────
            let headerHeight: CGFloat = 36
            cgCtx.setFillColor(UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1).cgColor)
            cgCtx.fill(CGRect(x: margin, y: y - headerHeight, width: contentWidth, height: headerHeight))
            drawText(String(localized: "pdf_title"), at: CGPoint(x: margin + 10, y: y - 26),
                     font: .boldSystemFont(ofSize: 16), color: .white)
            y -= headerHeight + 12

            // ── Timestamp ────────────────────────────────────────────────────
            let tsLabel = String(format: String(localized: "pdf_generated"), ts.replacingOccurrences(of: "_", with: " "))
            drawText(tsLabel, at: CGPoint(x: margin, y: y),
                     font: .systemFont(ofSize: 9), color: .gray)
            y -= 20

            // ── Photo (top-right) ────────────────────────────────────────────
            let photoW: CGFloat = 90, photoH: CGFloat = 112
            var photoPlaced = false
            if let photoData = result.photo, let img = UIImage(data: photoData) {
                let photoX = pageRect.width - margin - photoW
                img.draw(in: CGRect(x: photoX, y: y - photoH, width: photoW, height: photoH))
                photoPlaced = true
            }
            let tableRight = photoPlaced ? pageRect.width - margin - photoW - 12 : pageRect.width - margin

            // ── Identity section ─────────────────────────────────────────────
            drawText(String(localized: "pdf_section_identity"), at: CGPoint(x: margin, y: y),
                     font: .boldSystemFont(ofSize: 11), color: .black)
            y -= 16

            let colLeft  = margin
            let colRight = margin + (tableRight - margin) / 2 + 4

            let id = result.identity
            let pd = result.personalData

            func row(_ label: String, _ value: String?, _ col: CGFloat, _ rowY: CGFloat) {
                drawText(label.uppercased(), at: CGPoint(x: col, y: rowY + 1),
                         font: .systemFont(ofSize: 8), color: .gray)
                drawText(value ?? "-", at: CGPoint(x: col, y: rowY - 10),
                         font: .systemFont(ofSize: 10), color: .black)
            }

            row(String(localized: "pdf_field_full_name"),
                id.map { "\($0.firstName) \($0.lastName)" }, colLeft, y)
            row(String(localized: "pdf_field_cnp"), id?.cnp, colRight, y)
            y -= 28
            row(String(localized: "pdf_field_dob"), id.map { formatDob($0.dateOfBirth) }, colLeft, y)
            row(String(localized: "pdf_field_nationality"), id?.nationality, colRight, y)
            y -= 28
            row(String(localized: "pdf_field_birthplace"), pd?.birthPlace, colLeft, y)
            row(String(localized: "pdf_field_doc_no"), pd?.documentNumber, colRight, y)
            y -= 28
            if let issue = pd?.issueDate { row(String(localized: "pdf_field_issue_date"), formatDob(issue), colLeft, y) }
            if let exp = pd?.expiryDate  { row(String(localized: "pdf_field_expires"), formatDob(exp), colRight, y) }
            if pd?.issueDate != nil || pd?.expiryDate != nil { y -= 28 }
            if let auth = pd?.issuingAuthority {
                drawText(String(localized: "pdf_field_issuing_authority").uppercased(),
                         at: CGPoint(x: margin, y: y + 1), font: .systemFont(ofSize: 8), color: .gray)
                drawText(auth, at: CGPoint(x: margin, y: y - 10),
                         font: .systemFont(ofSize: 10), color: .black)
                y -= 28
            }
            if let addr = pd?.address {
                drawText(String(localized: "pdf_field_address").uppercased(),
                         at: CGPoint(x: margin, y: y + 1), font: .systemFont(ofSize: 8), color: .gray)
                let line1 = String(addr.prefix(65))
                let line2 = String(addr.dropFirst(65).prefix(65))
                drawText(line1, at: CGPoint(x: margin, y: y - 10), font: .systemFont(ofSize: 10), color: .black)
                if !line2.isEmpty {
                    drawText(line2, at: CGPoint(x: margin, y: y - 22), font: .systemFont(ofSize: 10), color: .black)
                    y -= 40
                } else {
                    y -= 28
                }
            }
            y -= 8

            // ── Divider ──────────────────────────────────────────────────────
            cgCtx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            cgCtx.move(to: CGPoint(x: margin, y: y))
            cgCtx.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            cgCtx.strokePath()
            y -= 16

            // ── Document Authenticity ────────────────────────────────────────
            drawText(String(localized: "pdf_section_authenticity"),
                     at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 11), color: .black)
            y -= 16

            switch result.passiveAuth {
            case .valid(let dsc, let issuer):
                let okGreen = UIColor(red: 0.18, green: 0.65, blue: 0.31, alpha: 1)
                drawText("[\(String(localized: "pdf_ok"))] \(String(localized: "result_passive_auth_valid"))",
                         at: CGPoint(x: margin, y: y), font: .systemFont(ofSize: 10), color: okGreen)
                y -= 14
                row(String(localized: "pdf_field_doc_cert"), dsc, margin, y); y -= 28
                row(String(localized: "pdf_field_issued_by"), issuer, margin, y); y -= 28
            case .invalid(let reason):
                drawText("[\(String(localized: "pdf_fail"))] \(reason)",
                         at: CGPoint(x: margin, y: y), font: .systemFont(ofSize: 10),
                         color: UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1))
                y -= 20
            case .notSupported:
                row(String(localized: "result_passive_auth_not_supported_label"),
                    String(localized: "result_passive_auth_not_supported_value"), margin, y)
                y -= 28
            }

            // ── Chip Genuineness ─────────────────────────────────────────────
            switch result.activeAuth {
            case .verified(let cert):
                drawText(String(localized: "pdf_section_chip"),
                         at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 11), color: .black)
                y -= 16
                let okGreen = UIColor(red: 0.18, green: 0.65, blue: 0.31, alpha: 1)
                drawText("[\(String(localized: "pdf_ok"))] \(String(localized: "result_active_auth_verified"))",
                         at: CGPoint(x: margin, y: y), font: .systemFont(ofSize: 10), color: okGreen)
                y -= 14
                row(String(localized: "pdf_field_chip_cert"), cert, margin, y); y -= 28
            case .failed(let reason):
                drawText(String(localized: "pdf_section_chip"),
                         at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 11), color: .black)
                y -= 16
                drawText("[\(String(localized: "pdf_fail"))] \(reason)",
                         at: CGPoint(x: margin, y: y), font: .systemFont(ofSize: 10),
                         color: UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1))
                y -= 20
            case .skipped: break
            }

            // ── Handwritten signature ────────────────────────────────────────
            if let sigData = result.signatureImage,
               let sigImg = UIImage(data: sigData),
               y > 130 {
                cgCtx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                cgCtx.move(to: CGPoint(x: margin, y: y)); cgCtx.addLine(to: CGPoint(x: pageRect.width - margin, y: y)); cgCtx.strokePath()
                y -= 16
                drawText(String(localized: "pdf_section_signature"),
                         at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 11), color: .black)
                y -= 14
                let drawH: CGFloat = 56
                let aspect = sigImg.size.width / max(sigImg.size.height, 1)
                let drawW  = min(aspect * drawH, contentWidth)
                sigImg.draw(in: CGRect(x: margin, y: y - drawH, width: drawW, height: drawH))
                y -= drawH + 8
            }

            // ── Footer ───────────────────────────────────────────────────────
            drawText("EidKit – \(ts.replacingOccurrences(of: "_", with: " "))",
                     at: CGPoint(x: margin, y: 24),
                     font: .systemFont(ofSize: 8), color: .gray)
        }

        let tempUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(filename)
        try data.write(to: tempUrl, options: .atomic)
        return tempUrl
    }

    // MARK: - Helpers

    private func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        text.draw(at: point, withAttributes: attrs)
    }

    private func formatDob(_ raw: String) -> String {
        guard raw.count == 8 else { return raw }
        return "\(raw.prefix(2))/\(raw.dropFirst(2).prefix(2))/\(raw.dropFirst(4))"
    }
}
