import CryptoKit
import Foundation

/// Sparkle EdDSA 签名校验。
///
/// Sparkle 2 用 Ed25519 对**整个安装包文件**签名，公钥放在应用自己的 `Info.plist`
/// 的 `SUPublicEDKey` 里，签名放在 appcast 的 `sparkle:edSignature` 里。
/// 两者对得上，就能证明这个安装包确实出自该应用的开发者——这是自动安装最后一道、
/// 也是最硬的一道防线。
///
/// 实测（AlDente 1.29 → 1.39.2）：本地 delta 与 11.6 MB 完整 dmg 均校验通过。
public enum SignatureVerifier {
    public enum Outcome: Equatable, Sendable {
        /// 校验通过。
        case verified
        /// 缺少公钥或签名，无法校验。不是失败，但界面上必须如实说明。
        case skipped(reason: String)
        /// 有签名但对不上，必须中止安装。
        case failed(reason: String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        public var isVerified: Bool { self == .verified }

        public var summary: String {
            switch self {
            case .verified: return "签名校验通过"
            case .skipped(let reason): return "未校验 · \(reason)"
            case .failed(let reason): return "签名校验失败 · \(reason)"
            }
        }
    }

    /// 校验一个本地文件。
    ///
    /// 用 `.mappedIfSafe` 读取：IINA 的安装包有 104 MB、ToDesk 有 359 MB，
    /// 全部读进内存没有必要，映射进地址空间即可满足 Ed25519 的单遍扫描。
    public static func verify(
        fileAt url: URL,
        signatureBase64: String?,
        publicKeyBase64: String?
    ) -> Outcome {
        guard let payload = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            if trimmed(publicKeyBase64) == nil {
                return .skipped(reason: "该应用未公布签名公钥")
            }
            if trimmed(signatureBase64) == nil {
                return .skipped(reason: "更新源未提供签名")
            }
            return .failed(reason: "安装包无法读取")
        }
        return verify(payload: payload, signatureBase64: signatureBase64, publicKeyBase64: publicKeyBase64)
    }

    /// 校验一段已经在手里的字节。自更新签的是清单，不是整个 zip。
    public static func verify(
        payload: Data,
        signatureBase64: String?,
        publicKeyBase64: String?
    ) -> Outcome {
        guard let publicKeyBase64 = trimmed(publicKeyBase64) else {
            return .skipped(reason: "该应用未公布签名公钥")
        }
        guard let signatureBase64 = trimmed(signatureBase64) else {
            return .skipped(reason: "更新源未提供签名")
        }
        guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32 else {
            return .failed(reason: "公钥格式不正确")
        }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64 else {
            return .failed(reason: "签名格式不正确")
        }

        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            return key.isValidSignature(signature, for: payload)
                ? .verified
                : .failed(reason: "签名与内容不匹配")
        } catch {
            return .failed(reason: "公钥无法使用")
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
