import Foundation

/// Holds all state between PAdES phase 1 (PDF preparation) and phase 2 (CMS embedding).
/// Kept in memory across the NFC session.
public final class PadesContext {

    /// SHA-384 hash of DER(signedAttrs) — this is what is sent to the card for signing.
    ///
    /// CMS requires: signature = Sign(SHA-384(DER(signedAttrs)))
    /// where signedAttrs contains messageDigest = SHA-384(PDF byte ranges).
    /// The card signs whatever 48-byte hash we hand it, so we send the signedAttrs hash,
    /// not the raw PDF byte-range hash.
    public let signedAttrsHash: Data

    /// Pre-built DER-encoded signedAttrs — embedded as-is in the CMS SignerInfo.
    let signedAttrsDer: Data

    /// Byte range offsets [start1, len1, start2, len2] of the content covered by the signature.
    let byteRanges: [Int]

    /// The prepared PDF with a zeroed-out signature placeholder, written to a temp file.
    let tempFileUrl: URL

    /// Suggested output filename.
    public let suggestedFilename: String

    init(signedAttrsHash: Data,
         signedAttrsDer: Data,
         byteRanges: [Int],
         tempFileUrl: URL,
         suggestedFilename: String) {
        self.signedAttrsHash  = signedAttrsHash
        self.signedAttrsDer   = signedAttrsDer
        self.byteRanges       = byteRanges
        self.tempFileUrl      = tempFileUrl
        self.suggestedFilename = suggestedFilename
    }
}
