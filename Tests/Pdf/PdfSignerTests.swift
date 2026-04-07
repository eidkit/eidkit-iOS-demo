import XCTest
import CryptoKit
@testable import EidKitApp

// MARK: - PdfSignerTests

final class PdfSignerTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal structurally-valid 1-page PDF with a proper Catalog→Pages→Page chain.
    /// PDFKit can open it; it has a well-formed xref and trailer.
    private static let minimalPdf: Data = {
        // Object offsets are tracked manually so the xref table is exact.
        var body = ""
        var offsets: [Int] = []

        body += "%PDF-1.4\n"
        offsets.append(body.utf8.count)
        body += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        offsets.append(body.utf8.count)
        body += "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        offsets.append(body.utf8.count)
        body += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"

        let xrefOffset = body.utf8.count
        body += "xref\n"
        body += "0 4\n"
        body += "0000000000 65535 f \n"
        body += String(format: "%010d 00000 n \n", offsets[0])
        body += String(format: "%010d 00000 n \n", offsets[1])
        body += String(format: "%010d 00000 n \n", offsets[2])
        body += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"

        return Data(body.utf8)
    }()

    /// Self-signed P-384 cert DER (CN=PdfSignerTest), valid for 10 years. Test-only.
    private static let testCertDer = Data(hexBytes: """
        308202b63082023b020900d98a9f81e2eac758300a06082a8648ce3d040302301831163014060355
        04030c0d5064665369676e657254657374301e170d3236303430373139353232385a170d33363034
        30343139353232385a30183116301406035504030c0d5064665369676e657254657374308201cc30
        82016406072a8648ce3d020130820157020101303c06072a8648ce3d0101023100ffffffffffffff
        fffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffff
        ff307b0430fffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000
        000000000000fffffffc0430b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088
        f5013875ac656398d8a2ed19d2a85c8edd3ec2aef031500a335926aa319a27a1d00896a6773a482
        7acdac73046104aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385
        502f25dbf55296c3a545e3872760ab73617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147c
        e9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f023100ffffffffffffffffffffffff
        ffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc5297302010103620004ec
        f4c9eba6bac402e5664f693f45a04772c04c27bfa35cc942e08002abd76a01819a5bb2fa7c95ca7
        0beb5fcebc2fadfee23a7bc18182619ae3601b0d7dadcd928071ccb4c0ba23083d5c24a530012b3
        16a663f6b3e0761ac6f7e6f92cf5dff9300a06082a8648ce3d0403020369003066023100f290bd0
        2289a8141472928cf67434ec6de6e8cc23230b6adbc40f9662ebc6d694ff8163ef4f6b351e7ccc2
        04890933cb023100f726c05c140733980dcf0de164b0ec5c9ad48c381507fd8de9d1e0b36198de1
        02e1ecef5ee81495bf3504182ae47e2fe
        """)

    /// A fake 96-byte raw ECDSA signature (all zeros). Structurally valid, cryptographically not.
    private static let fakeRawSignature = Data(repeating: 0x01, count: 96)

    // MARK: - Helpers

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try data.write(to: url)
        return url
    }

    private func runPrepare() async throws -> (ctx: PadesContext, pdf: Data) {
        let url = try writeTempFile(Self.minimalPdf)
        let signer = PdfSigner()
        let ctx = try await signer.prepare(url: url, displayName: "test.pdf", signedPrefix: "signed").get()
        let pdf = try Data(contentsOf: ctx.tempFileUrl)
        return (ctx, pdf)
    }

    // MARK: - prepare: ByteRange geometry

    func testPrepare_byteRangesHasFourElements() async throws {
        let (ctx, _) = try await runPrepare()
        XCTAssertEqual(ctx.byteRanges.count, 4)
    }

    func testPrepare_byteRangeStartsAtZero() async throws {
        let (ctx, _) = try await runPrepare()
        XCTAssertEqual(ctx.byteRanges[0], 0)
    }

    func testPrepare_byteRangeCoversWholeFile() async throws {
        let (ctx, pdf) = try await runPrepare()
        let r = ctx.byteRanges
        XCTAssertEqual(r[2] + r[3], pdf.count,
                       "r[2]+r[3] must equal total file size")
    }

    func testPrepare_byteRangeBoundariesAreDelimiters() async throws {
        // Range1 must end just before '<' and Range2 must start just after '>'
        let (ctx, pdf) = try await runPrepare()
        let r = ctx.byteRanges
        XCTAssertEqual(pdf[r[1]], UInt8(ascii: "<"),
                       "Byte immediately after Range1 must be '<'")
        XCTAssertEqual(pdf[r[2] - 1], UInt8(ascii: ">"),
                       "Byte immediately before Range2 must be '>'")
    }

    func testPrepare_gapBetweenRangesIsPlaceholderPlusDelimiters() async throws {
        let (ctx, _) = try await runPrepare()
        let r = ctx.byteRanges
        let gap = r[2] - (r[0] + r[1])
        // gap = '<' + 32768 hex zeros + '>'
        XCTAssertEqual(gap, 1 + 32_768 + 1)
    }

    // MARK: - prepare: signedAttrs integrity

    func testPrepare_signedAttrsHashIs48Bytes() async throws {
        let (ctx, _) = try await runPrepare()
        XCTAssertEqual(ctx.signedAttrsHash.count, 48,
                       "SHA-384 hash must be 48 bytes")
    }

    func testPrepare_signedAttrsHashMatchesHashOfSignedAttrsDer() async throws {
        let (ctx, _) = try await runPrepare()
        let expected = Data(SHA384.hash(data: ctx.signedAttrsDer))
        XCTAssertEqual(ctx.signedAttrsHash, expected,
                       "signedAttrsHash must equal SHA-384(signedAttrsDer)")
    }

    func testPrepare_messageDigestInSignedAttrsMatchesByteRangeHash() async throws {
        let (ctx, pdf) = try await runPrepare()
        let r = ctx.byteRanges

        // Recompute the SHA-384 over the two byte-range regions
        var hasher = SHA384()
        hasher.update(data: pdf[r[0] ..< r[0] + r[1]])
        hasher.update(data: pdf[r[2] ..< r[2] + r[3]])
        let expectedHash = Data(hasher.finalize())

        // Find the embedded messageDigest: search for OCTET STRING (0x04, 0x30 = len 48)
        // after the messageDigest OID in signedAttrsDer
        let mdOid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        let oidData = Data(mdOid)
        guard let oidRange = ctx.signedAttrsDer.range(of: oidData) else {
            return XCTFail("messageDigest OID not found in signedAttrsDer")
        }
        let after = ctx.signedAttrsDer[oidRange.upperBound...]
        let bytes = [UInt8](after)
        // SET (0x31) len, OCTET STRING (0x04) len=0x30 (48), hash bytes
        guard bytes.count >= 52, bytes[0] == 0x31, bytes[2] == 0x04, bytes[3] == 0x30 else {
            return XCTFail("Unexpected signedAttrsDer structure after messageDigest OID")
        }
        let embeddedDigest = Data(bytes[4..<52])
        XCTAssertEqual(embeddedDigest, expectedHash,
                       "messageDigest in signedAttrs must match SHA-384 of ByteRange content")
    }

    // MARK: - prepare: PDF structure

    func testPrepare_acrFormIsPresent() async throws {
        let (_, pdf) = try await runPrepare()
        let str = String(data: pdf, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(str.contains("/AcroForm"), "Prepared PDF must contain /AcroForm")
        XCTAssertTrue(str.contains("/SigFlags 3"), "Prepared PDF must contain /SigFlags 3")
    }

    func testPrepare_sigFieldIsPresent() async throws {
        let (_, pdf) = try await runPrepare()
        let str = String(data: pdf, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(str.contains("/FT /Sig"), "Prepared PDF must contain sig field widget")
        XCTAssertTrue(str.contains("/Type /Sig"), "Prepared PDF must contain sig dict")
    }

    func testPrepare_pageAnnotsIsPresent() async throws {
        let (_, pdf) = try await runPrepare()
        let str = String(data: pdf, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(str.contains("/Annots"), "Prepared PDF must wire sig widget to a page via /Annots")
    }

    func testPrepare_sigWidgetHasPageReference() async throws {
        let (_, pdf) = try await runPrepare()
        let str = String(data: pdf, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(str.contains("/P "), "Sig widget must have /P (page reference)")
    }

    func testPrepare_suggestedFilenameIncludesPrefix() async throws {
        let url = try writeTempFile(Self.minimalPdf)
        let ctx = try await PdfSigner()
            .prepare(url: url, displayName: "doc.pdf", signedPrefix: "semnat")
            .get()
        XCTAssertTrue(ctx.suggestedFilename.hasPrefix("semnat_"))
    }

    // MARK: - prepare: error handling

    func testPrepare_emptyDataThrows() async {
        let url = try! writeTempFile(Data())
        let result = await PdfSigner().prepare(url: url, displayName: "x.pdf", signedPrefix: "s")
        if case .success = result { XCTFail("Expected failure for empty file") }
    }

    func testPrepare_nonPdfThrows() async {
        let url = try! writeTempFile(Data("this is not a pdf at all".utf8))
        let result = await PdfSigner().prepare(url: url, displayName: "x.pdf", signedPrefix: "s")
        if case .success = result { XCTFail("Expected failure for non-PDF data") }
    }

    // MARK: - complete: round trip

    func testComplete_contentsPlaceholderIsReplaced() async throws {
        let (ctx, _) = try await runPrepare()
        let outUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await PdfSigner().complete(
            ctx: ctx,
            signatureBytes: Self.fakeRawSignature,
            certificateBytes: Self.testCertDer,
            outputUrl: outUrl
        ).get()

        let output = try Data(contentsOf: outUrl)
        let str = String(data: output, encoding: .ascii) ?? ""

        // The zeroed placeholder must be gone — the /Contents hex should start with 3082 (CMS SEQUENCE)
        let hasZeroPlaceholder = str.contains(String(repeating: "0", count: 32_768))
        XCTAssertFalse(hasZeroPlaceholder, "/Contents placeholder must be replaced with actual CMS bytes")
    }

    func testComplete_cmsStartsWithDerSequence() async throws {
        let (ctx, _) = try await runPrepare()
        let outUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await PdfSigner().complete(
            ctx: ctx,
            signatureBytes: Self.fakeRawSignature,
            certificateBytes: Self.testCertDer,
            outputUrl: outUrl
        ).get()

        let output = try Data(contentsOf: outUrl)

        // Extract the hex in /Contents <hex>
        guard let contentsRange = output.range(of: Data("/Contents <".utf8)) else {
            return XCTFail("Could not find /Contents in output PDF")
        }
        let hexStart = contentsRange.upperBound
        guard let endRange = output.range(of: Data(">".utf8), in: hexStart ..< output.endIndex) else {
            return XCTFail("Could not find closing '>' after /Contents")
        }
        let hexData = output[hexStart ..< endRange.lowerBound]
        guard let hexStr = String(data: hexData, encoding: .ascii), hexStr.count >= 4 else {
            return XCTFail("Could not decode /Contents hex")
        }
        // First byte of CMS ContentInfo must be 0x30 (SEQUENCE)
        let firstByteHex = String(hexStr.prefix(2))
        XCTAssertEqual(firstByteHex, "30", "CMS ContentInfo must start with DER SEQUENCE tag 0x30")
    }

    func testComplete_outputFileSizeMatchesByteRange() async throws {
        let (ctx, _) = try await runPrepare()
        let outUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await PdfSigner().complete(
            ctx: ctx,
            signatureBytes: Self.fakeRawSignature,
            certificateBytes: Self.testCertDer,
            outputUrl: outUrl
        ).get()

        let output = try Data(contentsOf: outUrl)
        let r = ctx.byteRanges
        XCTAssertEqual(r[2] + r[3], output.count,
                       "Output file size must match original ByteRange geometry")
    }

    func testComplete_byteRangeContentIsUnchanged() async throws {
        // The bytes covered by ByteRange must not change between prepare and complete —
        // only the /Contents hex changes (inside the excluded gap).
        let (ctx, prepared) = try await runPrepare()
        let outUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: outUrl) }

        try await PdfSigner().complete(
            ctx: ctx,
            signatureBytes: Self.fakeRawSignature,
            certificateBytes: Self.testCertDer,
            outputUrl: outUrl
        ).get()

        let output = try Data(contentsOf: outUrl)
        let r = ctx.byteRanges

        let preparedRange1 = prepared[r[0] ..< r[0] + r[1]]
        let outputRange1   = output[r[0] ..< r[0] + r[1]]
        XCTAssertEqual(preparedRange1, outputRange1, "Range1 bytes must be unchanged after complete()")

        let preparedRange2 = prepared[r[2] ..< r[2] + r[3]]
        let outputRange2   = output[r[2] ..< r[2] + r[3]]
        XCTAssertEqual(preparedRange2, outputRange2, "Range2 bytes must be unchanged after complete()")
    }
}

// MARK: - Data hex initializer (test-only)

private extension Data {
    init(hexBytes hex: String) {
        let cleaned = hex.components(separatedBy: .whitespacesAndNewlines).joined()
        var data = Data(capacity: cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            if let byte = UInt8(cleaned[i..<j], radix: 16) { data.append(byte) }
            i = j
        }
        self = data
    }
}
