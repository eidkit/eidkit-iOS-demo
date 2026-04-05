import Foundation
import CryptoKit
import PDFKit
import Security

private let reservedSignatureBytes = 32_768  // same as Android
private let oidEcdsaSha384: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]
private let oidSha384:      [UInt8] = [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]
private let oidData:        [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]

/// PAdES / CMS signing — pure Swift, no PDFBox dependency.
///
/// Phase 1 (`prepare`): insert a zeroed-out signature placeholder in the PDF and compute the
/// SHA-384 of the CMS signedAttrs. That hash goes to the card.
///
/// Phase 2 (`complete`): build the CMS SignedData blob with the card's ECDSA signature
/// and splice it into the placeholder, producing the final signed PDF.
final class PdfSigner {

    // MARK: - Phase 1

    func prepare(url: URL, displayName: String, signedPrefix: String) async -> Result<PadesContext, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try self.prepareSync(url: url, displayName: displayName, signedPrefix: signedPrefix) }
        }.value
    }

    private func prepareSync(url: URL, displayName: String, signedPrefix: String) throws -> PadesContext {
        let pdfData = try Data(contentsOf: url)
        guard pdfData.count > 4 else { throw PdfError("File is not a valid PDF") }

        // Write a copy to a temp file so PDFKit can mutate it
        let tempUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try pdfData.write(to: tempUrl)

        guard let doc = PDFDocument(url: tempUrl) else {
            throw PdfError("Could not open PDF document")
        }

        // Build signedAttrs with a placeholder messageDigest (all zeros, 48 bytes)
        // We'll compute the real PDF hash over the byte ranges after we know the placeholder offset.
        // Strategy: write placeholder, measure ranges, compute real hash, rebuild signedAttrs.
        let placeholder = Data(repeating: 0x00, count: reservedSignatureBytes)
        let (modifiedPdf, byteRanges) = try insertSignaturePlaceholder(
            pdfData: pdfData,
            placeholderSize: reservedSignatureBytes
        )

        // Hash the content covered by the byte ranges (everything except the signature hex)
        var hasher = SHA384()
        for i in stride(from: 0, to: byteRanges.count, by: 2) {
            let start = byteRanges[i]
            let length = byteRanges[i + 1]
            hasher.update(data: modifiedPdf[start ..< start + length])
        }
        let pdfHash = Data(hasher.finalize())

        // Build signedAttrs DER with the real PDF hash
        let signedAttrsDer = buildSignedAttrsDer(pdfHash: pdfHash)
        // The card signs SHA-384(DER(signedAttrs))
        let signedAttrsHash = Data(SHA384.hash(data: signedAttrsDer))

        // Write modified PDF (with placeholder) to temp file
        try modifiedPdf.write(to: tempUrl, options: .atomic)

        return PadesContext(
            signedAttrsHash:  signedAttrsHash,
            signedAttrsDer:   signedAttrsDer,
            byteRanges:       byteRanges,
            tempFileUrl:      tempUrl,
            suggestedFilename: "\(signedPrefix)_\(displayName)"
        )
    }

    // MARK: - Phase 2

    func complete(ctx: PadesContext,
                  signatureBytes: Data,
                  certificateBytes: Data,
                  outputUrl: URL) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try self.completeSync(ctx: ctx,
                                           signatureBytes: signatureBytes,
                                           certificateBytes: certificateBytes,
                                           outputUrl: outputUrl) }
        }.value
    }

    private func completeSync(ctx: PadesContext,
                               signatureBytes: Data,
                               certificateBytes: Data,
                               outputUrl: URL) throws {
        var pdfData = try Data(contentsOf: ctx.tempFileUrl)

        let cms = try buildCms(
            signedAttrsDer: ctx.signedAttrsDer,
            rawSignature:   signatureBytes,
            certDer:        certificateBytes
        )

        guard cms.count <= reservedSignatureBytes / 2 else {
            throw PdfError("CMS blob (\(cms.count) bytes) exceeds reserved space (\(reservedSignatureBytes / 2) bytes)")
        }

        // The placeholder is hex-encoded zeros in the PDF byte stream.
        // Replace it with the hex-encoded CMS blob, padded with zeros.
        let cmsHex = cms.hexString + String(repeating: "0", count: reservedSignatureBytes - cms.count * 2)
        let cmsHexData = Data(cmsHex.utf8)

        // Find the placeholder: a run of '0' ASCII bytes of length reservedSignatureBytes
        // located between the ByteRange and >> markers.
        guard let placeholderRange = findHexPlaceholder(in: pdfData, length: reservedSignatureBytes) else {
            throw PdfError("Could not locate signature placeholder in prepared PDF")
        }
        pdfData.replaceSubrange(placeholderRange, with: cmsHexData)

        try pdfData.write(to: outputUrl, options: .atomic)

        // Clean up temp file
        try? FileManager.default.removeItem(at: ctx.tempFileUrl)
    }

    // MARK: - PDF placeholder injection

    /// Insert an incremental update with a /ByteRange placeholder and zeroed signature content.
    /// Returns the modified PDF data and the resolved byte ranges [start1, len1, start2, len2].
    private func insertSignaturePlaceholder(pdfData: Data, placeholderSize: Int) throws -> (Data, [Int]) {
        // The hex-encoded placeholder occupies placeholderSize characters in the PDF stream.
        // We write a minimal PDF signature object appended as an incremental update.
        //
        // Structure appended:
        //   <xref table> <trailer> <signature dict with /Contents <000...0> and /ByteRange [...]>
        //
        // We use a simplified approach: construct the incremental update, measure the offsets,
        // then fix up the ByteRange.

        let baseLength = pdfData.count

        // Build signature dictionary with a temporary ByteRange (will be patched)
        let tempByteRange = "[0 999999 999999 999999]"
        let hexPlaceholder = String(repeating: "0", count: placeholderSize)

        var sigDict = ""
        sigDict += "1 0 obj\n"
        sigDict += "<< /Type /Sig\n"
        sigDict += "   /Filter /Adobe.PPKLite\n"
        sigDict += "   /SubFilter /ETSI.CAdES.detached\n"
        sigDict += "   /ByteRange \(tempByteRange)          \n"
        sigDict += "   /Contents <\(hexPlaceholder)>\n"
        sigDict += ">>\n"
        sigDict += "endobj\n"

        // Build AcroForm + page annotation pointing to sig object
        // (Minimal — no visible field, just the invisible signature object)
        var update = "\n"
        let sigObjOffset = baseLength + update.utf8.count
        update += sigDict

        let xrefOffset = baseLength + update.utf8.count
        update += "xref\n"
        update += "1 1\n"
        update += String(format: "%010d 00000 n \n", sigObjOffset)
        update += "trailer\n"
        update += "<< /Size 2 /Root 1 0 R /Prev \(baseLength) >>\n"
        update += "startxref\n"
        update += "\(xrefOffset)\n"
        update += "%%EOF\n"

        var combined = pdfData
        combined.append(Data(update.utf8))

        // Locate the /Contents < ... > span to determine byte ranges
        guard let contentsStart = findContentsValueStart(in: combined),
              let contentsEnd   = findContentsValueEnd(in: combined, after: contentsStart)
        else { throw PdfError("Could not locate /Contents placeholder offset") }

        // ByteRange: [before-contents, contents-start - 0, after-contents, rest]
        let range1Start  = 0
        let range1Length = contentsStart          // up to opening '<'
        let range2Start  = contentsEnd            // after closing '>'
        let range2Length = combined.count - contentsEnd

        let byteRange = [range1Start, range1Length, range2Start, range2Length]
        let byteRangeStr = "[\(byteRange[0]) \(byteRange[1]) \(byteRange[2]) \(byteRange[3])]"

        // Patch ByteRange in the PDF — find the temp value and replace it (same length via padding)
        let tempBytes = Data(tempByteRange.utf8)
        guard let rangeInPdf = combined.range(of: tempBytes) else {
            throw PdfError("Could not locate ByteRange placeholder")
        }
        var padded = byteRangeStr
        while padded.utf8.count < tempByteRange.utf8.count { padded += " " }
        combined.replaceSubrange(rangeInPdf, with: Data(padded.utf8))

        return (combined, byteRange)
    }

    private func findContentsValueStart(in data: Data) -> Int? {
        let marker = Data("/Contents <".utf8)
        guard let r = data.range(of: marker) else { return nil }
        return r.upperBound  // points at first char of hex string
    }

    private func findContentsValueEnd(in data: Data, after start: Int) -> Int? {
        // Find the closing '>' after the hex content
        let closeMarker = Data(">".utf8)
        let searchRange = start ..< data.endIndex
        guard let r = data.range(of: closeMarker, in: searchRange) else { return nil }
        return r.upperBound  // points past '>'
    }

    private func findHexPlaceholder(in data: Data, length: Int) -> Range<Data.Index>? {
        let zeros = Data(String(repeating: "0", count: length).utf8)
        return data.range(of: zeros)
    }

    // MARK: - CMS builder (raw ASN.1 — no dependencies)

    private func buildSignedAttrsDer(pdfHash: Data) -> Data {
        // SET {
        //   SEQUENCE { OID id-contentType, SET { OID id-data } }
        //   SEQUENCE { OID id-messageDigest, SET { OCTET STRING pdfHash } }
        // }
        let contentTypeAttr = asn1Seq([
            asn1OID(oidData),
            asn1Set([asn1OID(oidData)]),
        ])
        let msgDigestAttr = asn1Seq([
            asn1OID([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]),
            asn1Set([asn1OctetString(pdfHash)]),
        ])
        return asn1Set([contentTypeAttr, msgDigestAttr])
    }

    private func buildCms(signedAttrsDer: Data, rawSignature: Data, certDer: Data) throws -> Data {
        let derSig = try rawToDerEcdsa(rawSignature)

        // IssuerAndSerialNumber from cert
        let (issuerDer, serialDer) = try extractIssuerAndSerial(from: certDer)

        let issuerAndSerial = asn1Seq([issuerDer, serialDer])

        // Re-tag signedAttrs as [0] IMPLICIT
        let signedAttrsImplicit = asn1Tagged(0, signedAttrsDer, implicit: false)

        // SignerInfo
        let signerInfo = asn1Seq([
            asn1Integer(1),                                      // version
            issuerAndSerial,                                     // sid
            asn1Seq([asn1OID(oidSha384)]),                      // digestAlgorithm
            signedAttrsImplicit,                                 // [0] signedAttrs
            asn1Seq([asn1OID(oidEcdsaSha384)]),                 // signatureAlgorithm
            asn1OctetString(derSig),                            // signature
        ])

        // encapContentInfo (detached — no content)
        let encapContentInfo = asn1Seq([asn1OID(oidData)])

        // certificates [0] IMPLICIT
        let certsTagged = asn1Tagged(0, certDer, implicit: false)

        // SignedData
        let signedData = asn1Seq([
            asn1Integer(1),                                      // version
            asn1Set([asn1Seq([asn1OID(oidSha384)])]),           // digestAlgorithms
            encapContentInfo,                                    // encapContentInfo
            certsTagged,                                         // [0] certificates
            asn1Set([signerInfo]),                               // signerInfos
        ])

        // ContentInfo { OID signedData, [0] signedData }
        let signedDataOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let contentInfo = asn1Seq([
            asn1OID(signedDataOID),
            asn1Tagged(0, signedData, implicit: false),
        ])

        return contentInfo
    }

    private func rawToDerEcdsa(_ raw: Data) throws -> Data {
        guard raw.count == 96 else { throw PdfError("Expected 96-byte r||s, got \(raw.count)") }
        let r = encodeAsn1Integer(raw[raw.startIndex ..< raw.index(raw.startIndex, offsetBy: 48)])
        let s = encodeAsn1Integer(raw[raw.index(raw.startIndex, offsetBy: 48)...])
        return asn1Seq([r, s])
    }

    private func encodeAsn1Integer(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        while bytes.count > 1 && bytes[0] == 0x00 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return Data([0x02]) + berLength(bytes.count) + Data(bytes)
    }

    private func extractIssuerAndSerial(from certDer: Data) throws -> (Data, Data) {
        // Parse: SEQUENCE { SEQUENCE { [0] version, INTEGER serial, ... SEQUENCE issuer ... } }
        // We do a minimal parse to extract issuer and serial for IssuerAndSerialNumber.
        guard let cert = SecCertificateCreateWithData(nil, certDer as CFData) else {
            throw PdfError("Invalid certificate DER")
        }
        // Use raw ASN.1 walk: cert -> TBSCertificate -> skip version -> serial -> sig -> issuer
        // Minimal parser: find the outer SEQUENCE, then TBSCertificate SEQUENCE
        let bytes = [UInt8](certDer)
        var i = 0
        // outer SEQUENCE
        guard bytes[i] == 0x30 else { throw PdfError("Cert: expected SEQUENCE") }
        i += 1; i += berLengthSize(bytes, at: i) + 1
        // TBSCertificate SEQUENCE
        guard i < bytes.count, bytes[i] == 0x30 else { throw PdfError("Cert: expected TBSCertificate") }
        i += 1
        let tbsLenSize = berLengthSize(bytes, at: i)
        i += tbsLenSize + 1
        let tbsStart = i
        // skip optional [0] version
        if bytes[i] == 0xA0 { i += 1; let l = parseBerLength(bytes, at: i); i += berLengthSize(bytes, at: i) + 1 + l }
        // serial INTEGER
        guard bytes[i] == 0x02 else { throw PdfError("Cert: expected serial INTEGER") }
        let serialStart = i
        i += 1; let serialLen = parseBerLength(bytes, at: i); i += berLengthSize(bytes, at: i) + 1 + serialLen
        let serialDer = Data(bytes[serialStart ..< i])
        // signature AlgorithmIdentifier SEQUENCE
        guard bytes[i] == 0x30 else { throw PdfError("Cert: expected sigAlg") }
        i += 1; let sigAlgLen = parseBerLength(bytes, at: i); i += berLengthSize(bytes, at: i) + 1 + sigAlgLen
        // issuer Name SEQUENCE
        guard bytes[i] == 0x30 else { throw PdfError("Cert: expected issuer") }
        let issuerStart = i
        i += 1; let issuerLen = parseBerLength(bytes, at: i); i += berLengthSize(bytes, at: i) + 1 + issuerLen
        let issuerDer = Data(bytes[issuerStart ..< i])
        return (issuerDer, serialDer)
    }

    // MARK: - ASN.1 primitives

    private func asn1Seq(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + berLength(body.count) + body
    }

    private func asn1Set(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x31]) + berLength(body.count) + body
    }

    private func asn1OID(_ oidBytes: [UInt8]) -> Data {
        Data(oidBytes)
    }

    private func asn1OctetString(_ value: Data) -> Data {
        Data([0x04]) + berLength(value.count) + value
    }

    private func asn1Integer(_ value: Int) -> Data {
        Data([0x02, 0x01, UInt8(value)])
    }

    private func asn1Tagged(_ tag: UInt8, _ value: Data, implicit: Bool) -> Data {
        let t: UInt8 = implicit ? (0xA0 | tag) : (0xA0 | tag)
        return Data([t]) + berLength(value.count) + value
    }

    private func berLength(_ len: Int) -> Data {
        if len < 0x80  { return Data([UInt8(len)]) }
        if len <= 0xFF { return Data([0x81, UInt8(len)]) }
        return Data([0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
    }

    private func berLengthSize(_ bytes: [UInt8], at i: Int) -> Int {
        guard i < bytes.count else { return 0 }
        if bytes[i] < 0x80 { return 0 }
        return Int(bytes[i] & 0x7F)
    }

    private func parseBerLength(_ bytes: [UInt8], at i: Int) -> Int {
        guard i < bytes.count else { return 0 }
        let b = bytes[i]
        if b < 0x80 { return Int(b) }
        let n = Int(b & 0x7F)
        var len = 0
        for j in 1...n { len = (len << 8) | Int(bytes[i + j]) }
        return len
    }
}

// MARK: - Error

private struct PdfError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}

// MARK: - Data hex

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
