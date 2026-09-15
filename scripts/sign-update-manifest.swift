#!/usr/bin/env swift
import CryptoKit
import Foundation

/// 写出 `update.json`，若环境变量 `UPDRAFT_ED25519_PRIVATE_KEY` 有值则再写 `update.json.sig`。
/// 没配私钥时退出码仍是 0——对齐公证那套「没配凭据就降级，流水线不挂」。
///
/// 用法：
///   UPDRAFT_ED25519_PRIVATE_KEY=... swift scripts/sign-update-manifest.swift \
///     --version 0.3.0 --name Updraft-0.3.0-macOS.zip --sha256 <hex> \
///     --url https://github.com/midasism/Updraft/releases/download/v0.3.0/Updraft-0.3.0-macOS.zip \
///     --output-dir artifacts

func arg(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

guard let version = arg("--version"), !version.isEmpty,
      let name = arg("--name"), !name.isEmpty,
      let sha256 = arg("--sha256"), !sha256.isEmpty,
      let urlString = arg("--url"), let url = URL(string: urlString),
      let outputDir = arg("--output-dir"), !outputDir.isEmpty else {
    fail("缺少参数。需要 --version --name --sha256 --url --output-dir")
}

let object: [String: String] = [
    "name": name,
    "sha256": sha256.lowercased(),
    "url": url.absoluteString,
    "version": version
]
guard let json = try? JSONSerialization.data(
    withJSONObject: object,
    options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
) else {
    fail("无法序列化 update.json")
}

let jsonURL = URL(fileURLWithPath: outputDir).appendingPathComponent("update.json")
do {
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    try json.write(to: jsonURL, options: .atomic)
} catch {
    fail("无法写入 update.json：\(error)")
}
print("✔ 已写入 \(jsonURL.path)")

let keyB64 = ProcessInfo.processInfo.environment["UPDRAFT_ED25519_PRIVATE_KEY"]?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
if keyB64.isEmpty {
    print("→ 未配置 UPDRAFT_ED25519_PRIVATE_KEY，跳过清单签名")
    print("  本次产物不含 update.json.sig：客户端将标「未校验」而非失败")
    exit(0)
}

guard let keyData = Data(base64Encoded: keyB64), keyData.count == 32 else {
    fail("UPDRAFT_ED25519_PRIVATE_KEY 不是 32 字节 Ed25519 种子的 base64")
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let signature = try key.signature(for: json)
    let sigURL = URL(fileURLWithPath: outputDir).appendingPathComponent("update.json.sig")
    try Data(signature.base64EncodedString().utf8).write(to: sigURL, options: .atomic)
    print("✔ 已签名 \(sigURL.path)")
} catch {
    fail("签名失败：\(error)")
}
