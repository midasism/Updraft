import CryptoKit
import Foundation

/// 随 Release 发布的自更新清单。客户端先验签这份 JSON 的原始字节，再按里面的 sha256 核 zip。
public struct SelfUpdateManifest: Equatable, Sendable {
    public var version: String
    public var name: String
    public var sha256: String
    public var url: URL

    public init(version: String, name: String, sha256: String, url: URL) {
        self.version = version
        self.name = name
        self.sha256 = sha256
        self.url = url
    }

    /// 缺字段或 JSON 畸形一律返回 nil，不猜。
    public static func parse(_ data: Data) -> SelfUpdateManifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let version = nonEmpty(json["version"] as? String),
              let name = nonEmpty(json["name"] as? String),
              let sha256 = nonEmpty(json["sha256"] as? String),
              let rawURL = nonEmpty(json["url"] as? String),
              let url = URL(string: rawURL), url.scheme != nil else {
            return nil
        }
        return SelfUpdateManifest(version: version, name: name, sha256: sha256.lowercased(), url: url)
    }

    /// 给 CI 签名脚本用的稳定序列化。客户端验签用的是下载到的原始字节，不会走这里。
    public func jsonData() throws -> Data {
        let object: [String: String] = [
            "name": name,
            "sha256": sha256.lowercased(),
            "url": url.absoluteString,
            "version": version
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    public static func sha256Hex(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return sha256Hex(data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 签名文件可能是 base64 文本，也可能是 64 字节裸签名。
    ///
    /// 先认「解出来正好 64 字节」的 base64 文本（CI 写的就是这种），
    /// 否则 64 字节载荷按裸签名处理。不能见 UTF-8 就当文本——0x07 这类字节是合法 UTF-8，
    /// 但并不是签名的 base64。
    public static func signatureString(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let decoded = Data(base64Encoded: text),
           decoded.count == 64 {
            return text
        }
        guard !data.isEmpty else { return nil }
        if data.count == 64 {
            return data.base64EncodedString()
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return data.base64EncodedString()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// 自更新安装包的三道校验：清单 Ed25519 → zip SHA-256 → （解包后由 Installer 做 codesign）。
public enum SelfUpdateVerifier {
    public static func verifyDownloadedZip(
        zip: URL,
        manifestBytes: Data?,
        manifestSignature: String?,
        publicKey: String?
    ) -> SignatureVerifier.Outcome {
        let hasKey = !(publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasManifest = !(manifestBytes?.isEmpty ?? true)
        let hasSignature = !(manifestSignature?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if !hasKey {
            return .skipped(reason: "该应用未公布签名公钥")
        }
        if !hasManifest {
            return .skipped(reason: "更新源未提供签名清单")
        }
        if !hasSignature {
            return .skipped(reason: "更新源未提供签名")
        }

        let signed = SignatureVerifier.verify(
            payload: manifestBytes!,
            signatureBase64: manifestSignature,
            publicKeyBase64: publicKey
        )
        guard signed == .verified else { return signed }

        guard let manifest = SelfUpdateManifest.parse(manifestBytes!) else {
            return .failed(reason: "签名清单无法解析")
        }
        guard let actual = SelfUpdateManifest.sha256Hex(ofFile: zip) else {
            return .failed(reason: "安装包无法读取")
        }
        guard actual == manifest.sha256.lowercased() else {
            return .failed(reason: "安装包校验和与清单不符")
        }
        return .verified
    }
}
