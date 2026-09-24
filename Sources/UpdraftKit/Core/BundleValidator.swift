import Foundation

/// 安装包校验：代码签名、签名主体一致性、Bundle ID 比对。
extension Installer {
    func validate(
        stagedApp: URL,
        target: AppInfo,
        advertisedVersion: String,
        signature: SignatureVerifier.Outcome,
        warnings: inout [String]
    ) async throws -> String {
        guard let bundleID = target.bundleID else {
            throw InstallError.validationFailed("目标应用没有 Bundle ID")
        }
        guard let stagedBundleID = Self.bundleIdentifier(of: stagedApp), stagedBundleID == bundleID else {
            throw InstallError.validationFailed(
                "安装包的 Bundle ID 是 \(Self.bundleIdentifier(of: stagedApp) ?? "空")，与目标应用 \(bundleID) 不一致"
            )
        }

        let stagedVersion = Self.plistValue("CFBundleShortVersionString", in: stagedApp) ?? advertisedVersion
        if let current = target.currentVersion, !current.isEmpty {
            guard Version(stagedVersion) > Version(current) else {
                throw InstallError.validationFailed("安装包版本 \(stagedVersion) 不高于当前版本 \(current)")
            }
        }
        if Version(stagedVersion) != Version(advertisedVersion) {
            warnings.append("包内版本 \(stagedVersion) 与更新源宣称的 \(advertisedVersion) 不一致")
        }

        // 代码签名：先严格，严格不过再退到普通校验。
        let strict = await Self.verifyCodeSignature(stagedApp, deep: true)
        if !strict.ok {
            let plain = await Self.verifyCodeSignature(stagedApp, deep: false)
            guard plain.ok else {
                throw InstallError.validationFailed("代码签名无效：\(strict.detail)")
            }
            warnings.append("严格代码签名校验未通过，已退到普通校验（包完整性仍然有效）")
        }

        // 签名主体一致性：换了个开发者签名是要拦下来的事。
        let previous = await Self.signingIdentity(of: target.path)
        let incoming = await Self.signingIdentity(of: stagedApp)

        if let oldTeam = previous.teamID, !oldTeam.isEmpty, incoming.teamID != oldTeam {
            if signature.isVerified {
                warnings.append("签名主体由 \(oldTeam) 变为 \(incoming.teamID ?? "无")，但开发者签名校验已通过")
            } else {
                throw InstallError.validationFailed(
                    "签名主体发生变化（\(oldTeam) → \(incoming.teamID ?? "无")），且无法校验开发者签名"
                )
            }
        } else if previous.teamID == nil, let oldAuthority = previous.authority,
                  let newAuthority = incoming.authority, oldAuthority != newAuthority {
            if signature.isVerified {
                warnings.append("签名证书由「\(oldAuthority)」变为「\(newAuthority)」")
            } else {
                throw InstallError.validationFailed(
                    "签名证书发生变化（\(oldAuthority) → \(newAuthority)），且无法校验开发者签名"
                )
            }
        }

        return stagedVersion
    }

    struct SignatureCheck {
        let ok: Bool
        let detail: String
    }

    static func verifyCodeSignature(_ app: URL, deep: Bool) async -> SignatureCheck {
        var arguments = ["--verify"]
        if deep { arguments.append("--deep") }
        arguments.append("--strict")
        arguments.append(app.path)

        let result = await ProcessRunner.run(executable: "/usr/bin/codesign", arguments: arguments)
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        return SignatureCheck(
            ok: result.succeeded,
            detail: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    struct SigningIdentity: Sendable {
        var identifier: String?
        var teamID: String?
        var authority: String?
    }

    static func signingIdentity(of app: URL) async -> SigningIdentity {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=2", app.path]
        )
        let text = result.stderr.isEmpty ? result.stdout : result.stderr

        var identity = SigningIdentity()
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Identifier=") {
                identity.identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                identity.teamID = value == "not set" ? nil : value
            } else if line.hasPrefix("Authority="), identity.authority == nil {
                identity.authority = String(line.dropFirst("Authority=".count))
            }
        }
        return identity
    }

    func verifyInstalled(path: URL, bundleID: String, expectedVersion: String) async throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw InstallError.validationFailed("替换后目标路径不存在")
        }
        guard Self.bundleIdentifier(of: path) == bundleID else {
            throw InstallError.validationFailed("替换后的 Bundle ID 不正确")
        }
        let version = Self.plistValue("CFBundleShortVersionString", in: path)
        guard let version, Version(version) >= Version(expectedVersion) else {
            throw InstallError.validationFailed("替换后的版本号是 \(version ?? "空")，低于预期")
        }
        let check = await Self.verifyCodeSignature(path, deep: false)
        guard check.ok else {
            throw InstallError.validationFailed("替换后的包代码签名无效：\(check.detail)")
        }
    }
}
