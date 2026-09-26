import CryptoKit
import Foundation

/// 自更新安装包的 Ed25519 签名工具。
///
///     swift tools/ReleaseSign.swift keygen
///     swift tools/ReleaseSign.swift sign <私钥base64> <文件> [输出路径]
///     swift tools/ReleaseSign.swift verify <公钥base64> <文件> <签名文件>
///
/// 为什么需要它：应用给自己升级时，光有校验和不够——校验和跟安装包放在同一个
/// Release 里，能改包的人同样能改校验和，它只能证明"下载没坏"，证明不了"出自官方"。
/// Ed25519 签名用一把只存在于 GitHub Secrets 里的私钥，才是真正的信任锚。
///
/// 不配这把钥匙也不影响使用：应用会在界面上如实标注"未校验开发者签名"。
/// 这与项目里 `notarize.sh` 的路子一致——**配了就启用，没配就降级**，不留半成品状态。
///
/// 密钥直接以 base64 的原始字节形式流转（32 字节私钥 / 32 字节公钥 / 64 字节签名），
/// 与 Sparkle 的 `SUPublicEDKey` / `sparkle:edSignature` 完全一致，
/// 所以 `SignatureVerifier` 那份校验逻辑不用改一个字就能复用。
let arguments = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

func readPayload(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
        fail("读不到文件：\(path)")
    }
    return data
}

func decodeKey(_ base64: String, expecting count: Int, label: String) -> Data {
    let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed) else {
        fail("\(label)不是合法的 base64")
    }
    guard data.count == count else {
        fail("\(label)解出来是 \(data.count) 字节，应该是 \(count) 字节")
    }
    return data
}

guard arguments.count >= 2 else {
    fail("用法：keygen | sign <私钥base64> <文件> [输出路径] | verify <公钥base64> <文件> <签名文件>")
}

switch arguments[1] {
case "keygen":
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey.rawRepresentation
    let privateBase64 = privateKey.rawRepresentation.base64EncodedString()
    let publicBase64 = publicKey.base64EncodedString()

    print("生成了一对 Ed25519 密钥。两个都存进 GitHub 仓库的 Secrets：")
    print("")
    print("  名称  SELF_UPDATE_ED_KEY")
    print("  值    \(privateBase64)")
    print("  ── 私钥。只进 Secrets，不要提交进仓库，不要贴进任何 Issue。")
    print("")
    print("  名称  SELF_UPDATE_ED_PUBLIC_KEY")
    print("  值    \(publicBase64)")
    print("  ── 公钥。会被写进 Info.plist，本来就是公开的。")
    print("")
    print("配好之后，下一次打 tag 的产物就会自动带上 .ed25519 签名，")
    print("应用内自更新的「签名校验」那一行会从「未校验」变成「校验通过」。")

case "sign":
    guard arguments.count >= 4 else { fail("sign 需要 <私钥base64> 与 <文件>") }
    let key = decodeKey(arguments[2], expecting: 32, label: "私钥")
    let payload = readPayload(arguments[3])

    let signingKey: Curve25519.Signing.PrivateKey
    do {
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
    } catch {
        fail("私钥无法使用：\(error.localizedDescription)")
    }

    guard let signature = try? signingKey.signature(for: payload) else {
        fail("签名失败")
    }
    let encoded = signature.base64EncodedString()

    if arguments.count >= 5 {
        let output = URL(fileURLWithPath: arguments[4])
        do {
            try (encoded + "\n").write(to: output, atomically: true, encoding: .utf8)
        } catch {
            fail("写入 \(output.path) 失败：\(error.localizedDescription)")
        }
        print("✔ 已签名 \(arguments[3])")
        print("  签名文件 \(output.path)（\(signature.count) 字节）")
    } else {
        // 不换行，方便直接 `sign ... | pbcopy`
        FileHandle.standardOutput.write(Data(encoded.utf8))
    }

case "verify":
    guard arguments.count >= 5 else { fail("verify 需要 <公钥base64> <文件> <签名文件>") }
    let keyData = decodeKey(arguments[2], expecting: 32, label: "公钥")
    let payload = readPayload(arguments[3])
    guard let signatureText = try? String(contentsOfFile: arguments[4], encoding: .utf8),
          let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("读不到签名文件：\(arguments[4])")
    }

    let publicKey: Curve25519.Signing.PublicKey
    do {
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    } catch {
        fail("公钥无法使用：\(error.localizedDescription)")
    }

    if publicKey.isValidSignature(signature, for: payload) {
        print("✔ 签名有效：\(arguments[3])")
    } else {
        fail("签名与文件不匹配")
    }

default:
    fail("未知子命令 \(arguments[1])")
}
