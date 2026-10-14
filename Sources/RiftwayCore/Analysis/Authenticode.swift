import CryptoKit
import Foundation
import Security

/// The result of checking a PE file's Authenticode signature.
public enum SignatureStatus: Sendable, Equatable {
    case unsigned
    /// The PKCS#7 signature is intact and covers this exact file.
    /// `trusted` says whether macOS could build a chain to a root it trusts at
    /// the current date; an expired but timestamped certificate reads as untrusted.
    case signed(signer: String, trusted: Bool)
    /// A signature is present but the file was changed after signing, or the
    /// signature itself does not verify.
    case invalid(InvalidSignature)
    /// A signature is present in a format Riftway does not verify yet (MSI).
    case unverified
}

public enum InvalidSignature: String, Sendable, Equatable {
    /// The certificate table or the PKCS#7 structure can't be read.
    case malformed
    /// The image digest no longer matches: the file changed after signing.
    case modified
    /// The signature over the signed attributes does not verify.
    case badSignature
    /// A digest algorithm other than SHA-1 or SHA-256.
    case unsupportedAlgorithm
}

enum Authenticode {
    static let oidSHA1: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]
    static let oidSHA256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]

    static func verify(_ pe: PEFile) -> SignatureStatus {
        guard let table = pe.certificateTable else { return .unsigned }
        let r = pe.reader
        // WIN_CERTIFICATE: dwLength, wRevision, wCertificateType (2 = PKCS#7), bCertificate.
        guard let length = r.u32(table.lowerBound).map(Int.init), length > 8, length <= table.count,
              r.u16(table.lowerBound + 6) == 0x0002,
              let padded = r.bytes(table.lowerBound + 8, length - 8) else { return .invalid(.malformed) }
        // bCertificate is padded to eight bytes; CMS wants the DER element alone.
        guard let derLength = DER.elementLength([UInt8](padded.prefix(6))), derLength <= padded.count else {
            return .invalid(.malformed)
        }
        let pkcs7 = padded.prefix(derLength)

        guard let signed = SignedData(der: [UInt8](pkcs7)) else { return .invalid(.malformed) }

        // 1. The image digest stored in SpcIndirectDataContent matches this file.
        guard let (algorithm, expected) = digest(inIndirectData: signed.content) else {
            return .invalid(.malformed)
        }
        guard let actual = imageHash(pe, algorithm: algorithm) else { return .invalid(.unsupportedAlgorithm) }
        guard actual == expected else { return .invalid(.modified) }

        // 2. The signed attributes' messageDigest covers that content (its value,
        //    without the SEQUENCE header, as Authenticode specifies).
        guard let contentDigest = hash(signed.contentValue, algorithm: signed.digestAlgorithm),
              signed.messageDigest == contentDigest else { return .invalid(.badSignature) }

        // 3. One of the certificates signed those attributes.
        guard let signer = signed.certificates.first(where: { verifies(signed, with: $0) }) else {
            return .invalid(.badSignature)
        }
        let name = SecCertificateCopySubjectSummary(signer) as String? ?? "unknown signer"

        // 4. macOS can chain the signer to a root it trusts, at today's date.
        var trust: SecTrust?
        let chain = [signer] + signed.certificates.filter { $0 != signer }
        let trusted = SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess
            && trust.map { SecTrustEvaluateWithError($0, nil) } == true
        return .signed(signer: name, trusted: trusted)
    }

    static func verifies(_ signed: SignedData, with certificate: SecCertificate) -> Bool {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String else { return false }
        let sha256 = signed.digestAlgorithm == oidSHA256
        let algorithm: SecKeyAlgorithm
        if type == (kSecAttrKeyTypeRSA as String) {
            algorithm = sha256 ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA1
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            algorithm = sha256 ? .ecdsaSignatureMessageX962SHA256 : .ecdsaSignatureMessageX962SHA1
        } else {
            return false
        }
        return SecKeyVerifySignature(key, algorithm, Data(signed.signedAttributesAsSet) as CFData, Data(signed.signature) as CFData, nil)
    }

    static func hash(_ bytes: [UInt8], algorithm: [UInt8]) -> [UInt8]? {
        switch algorithm {
        case oidSHA256: Array(SHA256.hash(data: bytes))
        case oidSHA1: Array(Insecure.SHA1.hash(data: bytes))
        default: nil
        }
    }

    static func imageHash(_ pe: PEFile, algorithm: [UInt8]) -> [UInt8]? {
        switch algorithm {
        case oidSHA256: imageHash(pe, using: SHA256())
        case oidSHA1: imageHash(pe, using: Insecure.SHA1())
        default: nil
        }
    }

    /// The Authenticode image hash: the whole file except the checksum field, the
    /// certificate directory entry and the certificate table itself.
    static func imageHash<H: HashFunction>(_ pe: PEFile, using hasher: H) -> [UInt8] {
        var hasher = hasher
        let data = pe.reader.data
        var excluded = [pe.checksumOffset..<(pe.checksumOffset + 4),
                        pe.securityDirectoryOffset..<(pe.securityDirectoryOffset + 8)]
        if let table = pe.certificateTable { excluded.append(table) }
        var at = 0
        for gap in excluded.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if gap.lowerBound > at { feed(&hasher, data, at..<gap.lowerBound) }
            at = max(at, gap.upperBound)
        }
        if at < data.count { feed(&hasher, data, at..<data.count) }
        return Array(hasher.finalize())
    }

    private static func feed<H: HashFunction>(_ hasher: inout H, _ data: Data, _ range: Range<Int>) {
        // Large installers are memory-mapped; hash in chunks to keep pages streaming.
        var start = range.lowerBound
        let chunk = 8 << 20
        while start < range.upperBound {
            let end = min(start + chunk, range.upperBound)
            data[start..<end].withUnsafeBytes { hasher.update(bufferPointer: $0) }
            start = end
        }
    }

    /// SpcIndirectDataContent ::= SEQUENCE { data SEQUENCE, messageDigest DigestInfo }
    /// DigestInfo ::= SEQUENCE { SEQUENCE { algorithm OID, parameters }, digest OCTET STRING }
    static func digest(inIndirectData der: [UInt8]) -> (algorithm: [UInt8], digest: [UInt8])? {
        var top = DER(der)
        guard let outer = top.next(tag: 0x30) else { return nil }
        var items = DER(outer)
        guard items.next(tag: 0x30) != nil, let digestInfo = items.next(tag: 0x30) else { return nil }
        var info = DER(digestInfo)
        guard let algorithmID = info.next(tag: 0x30), let digest = info.next(tag: 0x04) else { return nil }
        var alg = DER(algorithmID)
        guard let oid = alg.next(tag: 0x06) else { return nil }
        return (oid, digest)
    }
}

/// The parts of an Authenticode PKCS#7 SignedData that verification needs.
struct SignedData {
    static let oidMessageDigest: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]

    /// SpcIndirectDataContent, as a whole element.
    var content: [UInt8]
    /// Its value without the SEQUENCE header: what messageDigest covers.
    var contentValue: [UInt8]
    var certificates: [SecCertificate]
    var digestAlgorithm: [UInt8]
    var messageDigest: [UInt8]
    /// The signed attributes re-tagged from [0] IMPLICIT to SET, the bytes the
    /// signature covers.
    var signedAttributesAsSet: [UInt8]
    var signature: [UInt8]

    init?(der: [UInt8]) {
        var top = DER(der)
        guard let contentInfo = top.next(tag: 0x30) else { return nil }
        var ci = DER(contentInfo)
        guard ci.next(tag: 0x06) != nil, let explicit = ci.next(tag: 0xA0) else { return nil }
        var wrapper = DER(explicit)
        guard let signedData = wrapper.next(tag: 0x30) else { return nil }
        var sd = DER(signedData)
        guard sd.next(tag: 0x02) != nil, sd.next(tag: 0x31) != nil, let encapsulated = sd.next(tag: 0x30) else { return nil }
        var encap = DER(encapsulated)
        guard encap.next(tag: 0x06) != nil, let explicitContent = encap.next(tag: 0xA0) else { return nil }
        var inner = DER(explicitContent)
        guard let element = inner.nextElement(), element.tag == 0x30 else { return nil }
        content = element.raw
        contentValue = element.value

        certificates = []
        if let certs = sd.next(tag: 0xA0) {
            var list = DER(certs)
            while let cert = list.nextElement() {
                if cert.tag == 0x30, let parsed = SecCertificateCreateWithData(nil, Data(cert.raw) as CFData) { certificates.append(parsed) }
            }
        }
        _ = sd.next(tag: 0xA1)  // CRLs
        guard let signerInfos = sd.next(tag: 0x31) else { return nil }
        var infos = DER(signerInfos)
        guard let signerInfo = infos.next(tag: 0x30) else { return nil }
        var si = DER(signerInfo)
        guard si.next(tag: 0x02) != nil, si.next(tag: 0x30) != nil, let digestAlg = si.next(tag: 0x30) else { return nil }
        var alg = DER(digestAlg)
        guard let oid = alg.next(tag: 0x06) else { return nil }
        digestAlgorithm = oid
        guard let attributes = si.nextElement(), attributes.tag == 0xA0 else { return nil }
        signedAttributesAsSet = [0x31] + attributes.raw.dropFirst()
        guard si.next(tag: 0x30) != nil, let encrypted = si.next(tag: 0x04) else { return nil }
        signature = encrypted

        var found: [UInt8]?
        var attrs = DER(attributes.value)
        while let attribute = attrs.next(tag: 0x30) {
            var a = DER(attribute)
            guard let type = a.next(tag: 0x06), type == Self.oidMessageDigest, let values = a.next(tag: 0x31) else { continue }
            var v = DER(values)
            found = v.next(tag: 0x04)
        }
        guard let found else { return nil }
        messageDigest = found
    }
}

/// A minimal DER reader: definite lengths only, which is all DER allows.
struct DER {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Total size (header and contents) of the element starting `header`.
    static func elementLength(_ header: [UInt8]) -> Int? {
        guard header.count >= 2 else { return nil }
        let first = Int(header[1])
        guard first & 0x80 != 0 else { return 2 + first }
        let count = first & 0x7F
        guard count > 0, count <= 4, header.count >= 2 + count else { return nil }
        return 2 + count + header[2..<(2 + count)].reduce(0) { $0 << 8 | Int($1) }
    }

    /// The contents of the next element when its tag matches.
    mutating func next(tag: UInt8) -> [UInt8]? {
        guard index < bytes.count, bytes[index] == tag else { return nil }
        return nextElement()?.value
    }

    /// The next element: its tag, its whole encoding and its contents.
    mutating func nextElement() -> (tag: UInt8, raw: [UInt8], value: [UInt8])? {
        guard index < bytes.count else { return nil }
        let start = index
        let tag = bytes[index]
        var i = index + 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
            length = bytes[i..<(i + count)].reduce(0) { $0 << 8 | Int($1) }
            i += count
        }
        guard length >= 0, i + length <= bytes.count else { return nil }
        index = i + length
        return (tag, Array(bytes[start..<index]), Array(bytes[i..<index]))
    }
}
