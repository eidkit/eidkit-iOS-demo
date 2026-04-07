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

    /// Parse the original PDF's trailer to extract /Root ref, /Size, and startxref offset.
    /// These are required to build a correct incremental update.
    private func parseOriginalTrailer(_ data: Data) throws -> (rootRef: String, size: Int, startxref: Int) {
        let bytes = [UInt8](data)
        let len = bytes.count

        // Search backwards for last "startxref" → this is the /Prev offset for our update
        let sxToken = [UInt8]("startxref".utf8)
        var sxPos = -1
        outer: for i in stride(from: len - sxToken.count, through: 0, by: -1) {
            for j in 0 ..< sxToken.count { if bytes[i + j] != sxToken[j] { continue outer } }
            sxPos = i; break
        }
        guard sxPos >= 0 else { throw PdfError("No startxref in PDF") }
        var p = sxPos + sxToken.count
        while p < len && (bytes[p] == 0x20 || bytes[p] == 0x0A || bytes[p] == 0x0D) { p += 1 }
        var numStr = ""
        while p < len && bytes[p] >= 0x30 && bytes[p] <= 0x39 {
            numStr.append(Character(UnicodeScalar(bytes[p]))); p += 1
        }
        guard let startxref = Int(numStr) else { throw PdfError("Invalid startxref value") }

        // Search backwards for last "trailer" dict → contains /Root and /Size
        let trToken = [UInt8]("trailer".utf8)
        var trPos = -1
        outerT: for i in stride(from: len - trToken.count, through: 0, by: -1) {
            for j in 0 ..< trToken.count { if bytes[i + j] != trToken[j] { continue outerT } }
            trPos = i; break
        }
        guard trPos >= 0 else { throw PdfError("No trailer in PDF") }
        let dictEnd = min(trPos + 512, len)
        let dictStr = String(bytes: Array(bytes[trPos ..< dictEnd]), encoding: .ascii) ?? ""

        guard let rootIdx = dictStr.range(of: "/Root ") else { throw PdfError("No /Root in trailer") }
        let rootParts = dictStr[rootIdx.upperBound...]
            .components(separatedBy: CharacterSet.whitespaces)
            .filter { !$0.isEmpty }
            .prefix(3)
        guard rootParts.count >= 3 else { throw PdfError("Malformed /Root in trailer") }
        let rootRef = "\(rootParts[0]) \(rootParts[1]) \(rootParts[2])"

        guard let sizeIdx = dictStr.range(of: "/Size ") else { throw PdfError("No /Size in trailer") }
        let sizeToken = dictStr[sizeIdx.upperBound...]
            .components(separatedBy: CharacterSet(charactersIn: " \n\r\t/>"))
            .first(where: { !$0.isEmpty }) ?? ""
        guard let size = Int(sizeToken) else { throw PdfError("Malformed /Size in trailer") }

        return (rootRef, size, startxref)
    }

    /// Insert an incremental update with a /ByteRange placeholder and zeroed signature content.
    /// Also adds a signature field and updates the catalog's /AcroForm so PDF readers
    /// discover the signature and show the signature panel.
    /// Returns the modified PDF data and the resolved byte ranges [start1, len1, start2, len2].
    private func insertSignaturePlaceholder(pdfData: Data, placeholderSize: Int) throws -> (Data, [Int]) {
        let baseLength = pdfData.count

        let (origRootRef, origSize, origStartxref) = try parseOriginalTrailer(pdfData)
        let rootParts    = origRootRef.components(separatedBy: " ")
        let catalogObjNum = Int(rootParts.first ?? "1") ?? 1
        let sigFieldObjNum = origSize          // N   — sig field widget
        let sigDictObjNum  = origSize + 1      // N+1 — sig dict (/Type /Sig)

        let tempByteRange  = "[0 999999 999999 999999]"
        let hexPlaceholder = String(repeating: "0", count: placeholderSize)

        // 1. Updated catalog: same object number, /AcroForm added
        let catalogStr = try updatedCatalogObj(pdfData: pdfData,
                                               catalogObjNum: catalogObjNum,
                                               sigFieldObjNum: sigFieldObjNum,
                                               sigDictObjNum: sigDictObjNum)

        // 2. Updated page: add /Annots so the sig widget is registered on the page
        let pageObjNum = firstPageObjNum(pdfData: pdfData, catalogObjNum: catalogObjNum)
        let pageStr    = try updatedPageObj(pdfData: pdfData,
                                            pageObjNum: pageObjNum,
                                            sigFieldObjNum: sigFieldObjNum)

        // 3. Sig field widget (invisible, linked to page via /P)
        let sigFieldStr = "\(sigFieldObjNum) 0 obj\n" +
                          "<< /FT /Sig /Type /Annot /Subtype /Widget\n" +
                          "   /T (Sig1) /V \(sigDictObjNum) 0 R\n" +
                          "   /Rect [0 0 0 0] /P \(pageObjNum) 0 R\n" +
                          ">>\nendobj\n"

        // 4. Sig dict with placeholder
        let signingDate = pdfDateString()
        let sigDictStr = "\(sigDictObjNum) 0 obj\n" +
                         "<< /Type /Sig\n" +
                         "   /Filter /Adobe.PPKLite\n" +
                         "   /SubFilter /ETSI.CAdES.detached\n" +
                         "   /M (\(signingDate))\n" +
                         "   /Reason (Semnatura electronica cu Cartea de Identitate Electronica Romana)\n" +
                         "   /ByteRange \(tempByteRange)          \n" +
                         "   /Contents <\(hexPlaceholder)>\n" +
                         ">>\nendobj\n"

        // Assemble incremental update — write objects sorted by number so xref subsections
        // can be listed in ascending order (required by some validators).
        let objList: [(num: Int, str: String)] = [
            (num: pageObjNum,     str: pageStr),
            (num: catalogObjNum,  str: catalogStr),
            (num: sigFieldObjNum, str: sigFieldStr),
            (num: sigDictObjNum,  str: sigDictStr),
        ].sorted { $0.num < $1.num }

        var update = "\n"
        var objOffsets: [Int: Int] = [:]
        for obj in objList {
            objOffsets[obj.num] = baseLength + update.utf8.count
            update += obj.str
        }
        let xrefOffset = baseLength + update.utf8.count

        // XRef: one subsection per updated object (always valid, even if non-contiguous)
        update += "xref\n"
        for obj in objList {
            update += "\(obj.num) 1\n"
            update += String(format: "%010d 00000 n \n", objOffsets[obj.num]!)
        }
        update += "trailer\n"
        update += "<< /Size \(sigDictObjNum + 1) /Root \(origRootRef) /Prev \(origStartxref) >>\n"
        update += "startxref\n"
        update += "\(xrefOffset)\n"
        update += "%%EOF\n"

        var combined = pdfData
        combined.append(Data(update.utf8))

        // Locate /Contents < ... > span to compute byte ranges.
        // contentsStart points to the first hex char (AFTER '<').
        // contentsEnd   points to the first byte AFTER '>'.
        // Per PDF spec the ByteRange must exclude both '<' and '>' delimiters,
        // so Range1 length = contentsStart-1 (stops before '<').
        guard let contentsStart = findContentsValueStart(in: combined),
              let contentsEnd   = findContentsValueEnd(in: combined, after: contentsStart)
        else { throw PdfError("Could not locate /Contents placeholder offset") }

        let byteRange    = [0, contentsStart - 1, contentsEnd, combined.count - contentsEnd]
        let byteRangeStr = "[\(byteRange[0]) \(byteRange[1]) \(byteRange[2]) \(byteRange[3])]"

        let tempBytes = Data(tempByteRange.utf8)
        guard let rangeInPdf = combined.range(of: tempBytes) else {
            throw PdfError("Could not locate ByteRange placeholder")
        }
        var padded = byteRangeStr
        while padded.utf8.count < tempByteRange.utf8.count { padded += " " }
        combined.replaceSubrange(rangeInPdf, with: Data(padded.utf8))

        return (combined, byteRange)
    }

    /// Find the object number of the first page by walking Catalog → Pages → Kids[0].
    /// This is safe against binary content streams that may accidentally contain "/Type /Page".
    private func firstPageObjNum(pdfData: Data, catalogObjNum: Int) -> Int {
        // Catalog contains /Pages N 0 R
        guard let pagesNum = extractRefValue(key: "/Pages", objNum: catalogObjNum, pdfData: pdfData) else { return 1 }
        // Pages node contains /Kids [X 0 R ...]
        guard let firstKid = extractRefValue(key: "/Kids [", objNum: pagesNum, pdfData: pdfData, stopAt: " ") else { return 1 }
        return firstKid
    }

    /// Find `objNum 0 obj` in pdfData, then extract the first integer reference after `key`.
    /// E.g. key="/Pages " → finds "/Pages 2 0 R" → returns 2.
    private func extractRefValue(key: String, objNum: Int, pdfData: Data, stopAt: String = " ") -> Int? {
        let bytes   = [UInt8](pdfData)
        let marker  = [UInt8]("\(objNum) 0 obj".utf8)
        var pos     = -1
        outer: for i in 0 ..< bytes.count - marker.count {
            for j in 0 ..< marker.count { if bytes[i + j] != marker[j] { continue outer } }
            pos = i; break
        }
        guard pos >= 0 else { return nil }
        // Search for key within the next 1024 bytes (the object dict header)
        let end = min(pos + 1024, bytes.count)
        let slice = bytes[pos ..< end]
        let sliceStr = String(bytes: Array(slice), encoding: .ascii) ?? ""
        guard let keyRange = sliceStr.range(of: key) else { return nil }
        let after = String(sliceStr[keyRange.upperBound...])
        let token = after.components(separatedBy: CharacterSet(charactersIn: " \n\r\t/[>")).first(where: { !$0.isEmpty }) ?? ""
        return Int(token)
    }

    /// Return an updated version of the given page object that adds /Annots referencing the sig field.
    private func updatedPageObj(pdfData: Data, pageObjNum: Int, sigFieldObjNum: Int) throws -> String {
        let bytes = [UInt8](pdfData)
        let marker = [UInt8]("\(pageObjNum) 0 obj".utf8)
        var pos = -1
        outerP: for i in 0 ..< bytes.count - marker.count {
            for j in 0 ..< marker.count { if bytes[i + j] != marker[j] { continue outerP } }
            pos = i; break
        }
        guard pos >= 0 else { throw PdfError("Page object \(pageObjNum) not found") }
        var i = pos + marker.count
        while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D) { i += 1 }
        guard i + 1 < bytes.count, bytes[i] == 0x3C, bytes[i + 1] == 0x3C else {
            throw PdfError("Expected << after page object header")
        }
        var depth = 0
        let dictStart = i
        var dictEnd = -1
        while i < bytes.count {
            if bytes[i] == 0x3C, i + 1 < bytes.count, bytes[i + 1] == 0x3C {
                depth += 1; i += 2
            } else if bytes[i] == 0x3E, i + 1 < bytes.count, bytes[i + 1] == 0x3E {
                depth -= 1; i += 2
                if depth == 0 { dictEnd = i; break }
            } else if bytes[i] == 0x28 {
                i += 1
                while i < bytes.count && bytes[i] != 0x29 {
                    if bytes[i] == 0x5C { i += 1 }
                    i += 1
                }
                i += 1
            } else { i += 1 }
        }
        guard dictEnd >= 0 else { throw PdfError("Could not find end of page dict") }
        guard var dictStr = String(bytes: Array(bytes[dictStart..<dictEnd]), encoding: .isoLatin1) else {
            throw PdfError("Could not decode page dict")
        }
        if !dictStr.contains("/Annots") {
            if let last = dictStr.range(of: ">>", options: .backwards) {
                dictStr.replaceSubrange(last, with: "\n   /Annots [\(sigFieldObjNum) 0 R]\n>>")
            }
        }
        return "\(pageObjNum) 0 obj\n\(dictStr)\nendobj\n"
    }

    /// Read the original catalog object from the PDF and return an updated version
    /// that includes an /AcroForm pointing to the sig field.
    private func updatedCatalogObj(pdfData: Data, catalogObjNum: Int,
                                   sigFieldObjNum: Int, sigDictObjNum: Int) throws -> String {
        let bytes = [UInt8](pdfData)
        let marker = [UInt8]("\(catalogObjNum) 0 obj".utf8)

        // Find the catalog object in the file
        var pos = -1
        outer: for i in 0 ..< bytes.count - marker.count {
            for j in 0 ..< marker.count { if bytes[i + j] != marker[j] { continue outer } }
            pos = i; break
        }
        guard pos >= 0 else { throw PdfError("Catalog object \(catalogObjNum) not found") }

        // Skip to start of dict
        var i = pos + marker.count
        while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D) { i += 1 }
        guard i + 1 < bytes.count, bytes[i] == 0x3C, bytes[i + 1] == 0x3C else {
            throw PdfError("Expected << after catalog object header")
        }

        // Depth-count << / >> to find the matching closing >>
        var depth = 0
        let dictStart = i
        var dictEnd   = -1
        while i < bytes.count {
            if bytes[i] == 0x3C, i + 1 < bytes.count, bytes[i + 1] == 0x3C {
                depth += 1; i += 2
            } else if bytes[i] == 0x3E, i + 1 < bytes.count, bytes[i + 1] == 0x3E {
                depth -= 1; i += 2
                if depth == 0 { dictEnd = i; break }
            } else if bytes[i] == 0x28 {   // literal string ( ... )
                i += 1
                while i < bytes.count && bytes[i] != 0x29 {
                    if bytes[i] == 0x5C { i += 1 }   // skip escape
                    i += 1
                }
                i += 1
            } else { i += 1 }
        }
        guard dictEnd >= 0 else { throw PdfError("Could not find end of catalog dict") }

        guard var dictStr = String(bytes: Array(bytes[dictStart ..< dictEnd]), encoding: .isoLatin1) else {
            throw PdfError("Could not decode catalog dict")
        }

        // Insert /AcroForm before the outermost closing >>
        if !dictStr.contains("/AcroForm") {
            // Replace the last ">>" with our AcroForm entry + >>
            if let last = dictStr.range(of: ">>", options: .backwards) {
                dictStr.replaceSubrange(last,
                    with: "\n   /AcroForm << /Fields [\(sigFieldObjNum) 0 R] /SigFlags 3 >>\n>>")
            }
        }

        return "\(catalogObjNum) 0 obj\n\(dictStr)\nendobj\n"
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
        //   SEQUENCE { OID id-contentType,   SET { OID id-data } }
        //   SEQUENCE { OID id-messageDigest, SET { OCTET STRING pdfHash } }
        // }
        let oidContentType: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]
        let oidMsgDigest:   [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        let contentTypeAttr = asn1Seq([
            asn1OID(oidContentType),
            asn1Set([asn1OID(oidData)]),
        ])
        let msgDigestAttr = asn1Seq([
            asn1OID(oidMsgDigest),
            asn1Set([asn1OctetString(pdfHash)]),
        ])
        return asn1Set([contentTypeAttr, msgDigestAttr])
    }

    private func buildCms(signedAttrsDer: Data, rawSignature: Data, certDer: Data) throws -> Data {
        let derSig = try rawToDerEcdsa(rawSignature)

        // IssuerAndSerialNumber from cert
        let (issuerDer, serialDer) = try extractIssuerAndSerial(from: certDer)

        let issuerAndSerial = asn1Seq([issuerDer, serialDer])

        // signedAttrs [0] IMPLICIT SET — RFC 5652 §5.3: retag 0x31 → 0xA0 (do not wrap).
        // Verifier strips the context tag, restores 0x31, and hashes that — must match signedAttrsDer.
        var signedAttrsTagged = signedAttrsDer
        signedAttrsTagged[signedAttrsTagged.startIndex] = 0xA0

        // SignerInfo
        let signerInfo = asn1Seq([
            asn1Integer(1),                                      // version
            issuerAndSerial,                                     // sid
            asn1Seq([asn1OID(oidSha384)]),                      // digestAlgorithm
            signedAttrsTagged,                                   // [0] IMPLICIT signedAttrs
            asn1Seq([asn1OID(oidEcdsaSha384)]),                 // signatureAlgorithm
            asn1OctetString(derSig),                            // signature
        ])

        // encapContentInfo (detached — no content)
        let encapContentInfo = asn1Seq([asn1OID(oidData)])

        // certificates [0] IMPLICIT SET OF Certificate — wrap cert in SET, retag 0x31 → 0xA0
        var certsTagged = asn1Set([certDer])
        certsTagged[certsTagged.startIndex] = 0xA0

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

    private func pdfDateString() -> String {
        // PDF date format: D:YYYYMMDDHHmmSSOHH'mm'
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        return String(format: "D:%04d%02d%02d%02d%02d%02dZ",
                      comps.year ?? 2000, comps.month ?? 1, comps.day ?? 1,
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
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
