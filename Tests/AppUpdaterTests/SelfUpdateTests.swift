import CryptoKit
import XCTest
@testable import AppUpdaterKit

final class StubHTTPClient: HTTPFetching, @unchecked Sendable {
    var responses: [String: Result<Data, Error>] = [:]
    var requested: [String] = []

    func data(from url: URL) async throws -> Data {
        requested.append(url.absoluteString)
        if let result = responses[url.absoluteString] {
            return try result.get()
        }
        if let result = responses[url.lastPathComponent] {
            return try result.get()
        }
        for (key, result) in responses where url.absoluteString.contains(key) {
            return try result.get()
        }
        throw HTTPError.statusCode(404)
    }
}

final class SelfUpdateManifestTests: XCTestCase {
    func testParsesCompleteManifest() throws {
        let json = """
        {"version":"0.3.0","name":"Updraft-0.3.0-macOS.zip","sha256":"AbCDEF","url":"https://example.com/a.zip"}
        """.data(using: .utf8)!
        let manifest = SelfUpdateManifest.parse(json)
        XCTAssertEqual(manifest?.version, "0.3.0")
        XCTAssertEqual(manifest?.name, "Updraft-0.3.0-macOS.zip")
        XCTAssertEqual(manifest?.sha256, "abcdef")
        XCTAssertEqual(manifest?.url.absoluteString, "https://example.com/a.zip")
    }

    func testMalformedOrIncompleteYieldsNil() {
        XCTAssertNil(SelfUpdateManifest.parse(Data("not-json".utf8)))
        XCTAssertNil(SelfUpdateManifest.parse(Data("{}".utf8)))
        XCTAssertNil(SelfUpdateManifest.parse(Data(#"{"version":"1","name":"a.zip","sha256":"ab"}"#.utf8)))
        XCTAssertNil(SelfUpdateManifest.parse(Data(#"{"version":"1","name":"a.zip","sha256":"ab","url":"not-a-url"}"#.utf8)))
    }

    func testSignatureStringAcceptsBase64TextOrRawBytes() {
        let raw = Data(repeating: 0xA5, count: 64)
        let encoded = raw.base64EncodedString()
        XCTAssertEqual(SelfUpdateManifest.signatureString(from: Data("\(encoded)\n".utf8)), encoded)
        XCTAssertEqual(SelfUpdateManifest.signatureString(from: raw), encoded)
        // 合法 UTF-8 但不是 64 字节签名的 base64，不能误当成文本。
        let bell = Data(repeating: 7, count: 64)
        XCTAssertEqual(SelfUpdateManifest.signatureString(from: bell), bell.base64EncodedString())
    }
}

final class SelfUpdateCheckerTests: XCTestCase {
    private let zipURL = "https://github.com/midasism/Updraft/releases/download/v0.3.0/Updraft-0.3.0-macOS.zip"

    private func githubJSON(tag: String, assets: [[String: Any]]) -> Data {
        let body: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/midasism/Updraft/releases/tag/\(tag)",
            "assets": assets
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func zipAsset(name: String = "Updraft-0.3.0-macOS.zip", size: Int = 4_000_000) -> [String: Any] {
        ["name": name, "browser_download_url": zipURL, "size": size]
    }

    func testNewerTagIsUpdateAvailable() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.3.0", assets: [zipAsset()]))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        guard case .updateAvailable(let release) = status else {
            return XCTFail("应报有更新，实际 \(status)")
        }
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertEqual(release.downloadURL.absoluteString, zipURL)
        XCTAssertEqual(release.size, 4_000_000)
    }

    func testSameTagIsUpToDate() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.2.2", assets: [zipAsset()]))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .upToDate(latest: "0.2.2"))
    }

    func testOlderRemoteIsUpToDateNotGuessed() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.2.1", assets: [zipAsset()]))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .upToDate(latest: "0.2.1"))
    }

    func testMissingCurrentVersionFailsWithoutHittingNetwork() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.3.0", assets: [zipAsset()]))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "  ")
        XCTAssertEqual(status, .failed(reason: "无法读取本机版本号"))
        XCTAssertTrue(client.requested.isEmpty, "版本号都没有就不该发请求")
    }

    func testMalformedJSONIsFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(Data("<html>nope".utf8))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .failed(reason: "GitHub 返回内容无法解析"))
    }

    func testMissingTagNameIsFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(Data("{}".utf8))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .failed(reason: "该仓库没有正式 Release"))
    }

    func testHTTP404IsFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .failure(HTTPError.statusCode(404))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .failed(reason: "GitHub 返回 404，没有可用的 Release"))
    }

    func testHTTP403IsRateLimitFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .failure(HTTPError.statusCode(403))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .failed(reason: "GitHub 接口触发频率限制"))
    }

    func testTimeoutIsFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .failure(URLError(.timedOut))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        guard case .failed(let reason) = status else {
            return XCTFail("超时应报失败")
        }
        XCTAssertEqual(reason, "请求超时")
    }

    func testNewerReleaseWithoutZipIsFailure() async {
        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.3.0", assets: [
            ["name": "Updraft-0.3.0-macOS.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 1]
        ]))
        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        XCTAssertEqual(status, .failed(reason: "Release 里没有 zip 安装包"))
    }

    func testAttachesManifestWhenPresent() async {
        let key = Curve25519.Signing.PrivateKey()
        let zipBytes = Data("zip-bytes".utf8)
        let sha = SelfUpdateManifest.sha256Hex(zipBytes)
        let manifest = try! SelfUpdateManifest(
            version: "0.3.0",
            name: "Updraft-0.3.0-macOS.zip",
            sha256: sha,
            url: URL(string: zipURL)!
        ).jsonData()
        let signature = try! key.signature(for: manifest).base64EncodedString()

        let client = StubHTTPClient()
        client.responses["releases/latest"] = .success(githubJSON(tag: "v0.3.0", assets: [
            zipAsset(),
            ["name": "update.json", "browser_download_url": "https://example.com/update.json", "size": manifest.count],
            ["name": "update.json.sig", "browser_download_url": "https://example.com/update.json.sig", "size": signature.count]
        ]))
        client.responses["update.json"] = .success(manifest)
        client.responses["update.json.sig"] = .success(Data(signature.utf8))

        let status = await SelfUpdateChecker(client: client).check(currentVersion: "0.2.2")
        guard case .updateAvailable(let release) = status else {
            return XCTFail("应报有更新")
        }
        XCTAssertEqual(release.sha256, sha)
        XCTAssertEqual(release.manifestSignature, signature)
        XCTAssertEqual(release.manifestBytes, manifest)
    }

    func testPickZipPrefersUpdraftMacOSZipAndIgnoresSource() {
        let assets: [[String: Any]] = [
            ["name": "Source.zip", "browser_download_url": "https://x/Source.zip", "size": 1],
            ["name": "Updraft-0.3.0-macOS.zip", "browser_download_url": zipURL, "size": 9]
        ]
        XCTAssertEqual(SelfUpdateChecker.pickZip(from: assets)?.url.absoluteString, zipURL)
        XCTAssertNil(SelfUpdateChecker.pickZip(from: [
            ["name": "Updraft-0.3.0-macOS.dmg", "browser_download_url": "https://x/a.dmg", "size": 1]
        ]))
    }
}

final class SelfUpdateVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdateVerifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func writeZip(_ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent("Updraft.zip")
        try bytes.write(to: url)
        return url
    }

    private func signedManifest(for zip: Data, key: Curve25519.Signing.PrivateKey) throws -> (Data, String) {
        let sha = SelfUpdateManifest.sha256Hex(zip)
        let bytes = try SelfUpdateManifest(
            version: "0.3.0",
            name: "Updraft-0.3.0-macOS.zip",
            sha256: sha,
            url: URL(string: "https://example.com/Updraft-0.3.0-macOS.zip")!
        ).jsonData()
        return (bytes, try key.signature(for: bytes).base64EncodedString())
    }

    func testAcceptsGenuineManifestAndMatchingChecksum() throws {
        let key = Curve25519.Signing.PrivateKey()
        let zip = Data("real zip bytes".utf8)
        let file = try writeZip(zip)
        let (manifest, signature) = try signedManifest(for: zip, key: key)

        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: manifest,
            manifestSignature: signature,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertEqual(outcome, .verified)
    }

    func testRejectsTamperedZip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = Data("original zip".utf8)
        let (manifest, signature) = try signedManifest(for: original, key: key)
        let file = try writeZip(Data("tampered zip".utf8))

        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: manifest,
            manifestSignature: signature,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure, "zip 被换必须失败")
    }

    func testRejectsWrongPublicKey() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let zip = Data("zip".utf8)
        let file = try writeZip(zip)
        let (manifest, signature) = try signedManifest(for: zip, key: signer)

        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: manifest,
            manifestSignature: signature,
            publicKey: impostor.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure, "换公钥必须失败")
    }

    func testSkipsWhenPublicKeyMissing() throws {
        let file = try writeZip(Data("x".utf8))
        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: Data("{}".utf8),
            manifestSignature: "AAAA",
            publicKey: nil
        )
        XCTAssertEqual(outcome, .skipped(reason: "该应用未公布签名公钥"))
        XCTAssertFalse(outcome.isFailure)
    }

    func testSkipsWhenManifestMissing() throws {
        let file = try writeZip(Data("x".utf8))
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: nil,
            manifestSignature: "AAAA",
            publicKey: key
        )
        XCTAssertEqual(outcome, .skipped(reason: "更新源未提供签名清单"))
        XCTAssertFalse(outcome.isFailure, "缺清单是未校验，不是失败")
    }

    func testSkipsWhenSignatureMissing() throws {
        let file = try writeZip(Data("x".utf8))
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: Data(#"{"version":"1","name":"a.zip","sha256":"ab","url":"https://x/a.zip"}"#.utf8),
            manifestSignature: nil,
            publicKey: key
        )
        XCTAssertEqual(outcome, .skipped(reason: "更新源未提供签名"))
    }

    func testRejectsMalformedManifestEvenIfSignaturePasses() throws {
        let key = Curve25519.Signing.PrivateKey()
        let garbage = Data("{\"nope\":true}".utf8)
        let signature = try key.signature(for: garbage).base64EncodedString()
        let file = try writeZip(Data("zip".utf8))

        let outcome = SelfUpdateVerifier.verifyDownloadedZip(
            zip: file,
            manifestBytes: garbage,
            manifestSignature: signature,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure)
        if case .failed(let reason) = outcome {
            XCTAssertEqual(reason, "签名清单无法解析")
        }
    }
}

final class SelfUpdateRecoveryTests: XCTestCase {
    private var root: URL!
    private let token = "A1B2C3D4"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdateRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func makeBundle(at url: URL, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": SelfUpdateIdentity.bundleID,
            "CFBundleExecutable": "AppUpdater",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("AppUpdater")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return url
    }

    func testNewInstanceCleansDisplacedOldBundle() throws {
        try makeBundle(at: root.appendingPathComponent("AppUpdater.app"), version: "0.3.0")
        try makeBundle(
            at: root.appendingPathComponent(".AppUpdater.\(token).old.app"),
            version: "0.2.2"
        )

        let report = Installer.recoverInterruptedInstalls(in: [root])
        XCTAssertTrue(report.rescuedApps.isEmpty)
        XCTAssertEqual(report.removedArtifacts, [".AppUpdater.\(token).old.app"])
        XCTAssertEqual(
            Installer.plistValue("CFBundleShortVersionString", in: root.appendingPathComponent("AppUpdater.app")),
            "0.3.0"
        )
    }

    func testRescuesAppUpdaterWhenSwapWasInterrupted() throws {
        try makeBundle(
            at: root.appendingPathComponent(".AppUpdater.\(token).old.app"),
            version: "0.2.2"
        )

        let report = Installer.recoverInterruptedInstalls(in: [root])
        XCTAssertEqual(report.rescuedApps, ["AppUpdater"])
        let restored = root.appendingPathComponent("AppUpdater.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        XCTAssertEqual(Installer.plistValue("CFBundleShortVersionString", in: restored), "0.2.2")
        XCTAssertTrue(report.needsAttention.isEmpty)
    }

    func testKeepsArtifactsWhenNothingCanRescueAppUpdater() throws {
        try makeBundle(
            at: root.appendingPathComponent(".AppUpdater.\(token).new.app"),
            version: "0.3.0"
        )
        let report = Installer.recoverInterruptedInstalls(in: [root])
        XCTAssertTrue(report.rescuedApps.isEmpty)
        XCTAssertTrue(report.removedArtifacts.isEmpty)
        XCTAssertEqual(report.needsAttention.count, 1)
    }
}

final class SelfUpdateIdentityTests: XCTestCase {
    func testMainListExcludesSelf() {
        let selfApp = SelfUpdateIdentity.makeAppInfo(
            at: URL(fileURLWithPath: "/Applications/AppUpdater.app"),
            version: "0.2.2"
        )
        let other = AppInfo(
            name: "IINA",
            bundleID: "com.colliderli.iina",
            path: URL(fileURLWithPath: "/Applications/IINA.app"),
            currentVersion: "1.3.5",
            buildVersion: nil,
            source: .sparkle(feedURL: URL(string: "https://www.iina.io/appcast.xml"))
        )
        XCTAssertTrue(SelfUpdateIdentity.isSelf(selfApp))
        XCTAssertEqual(SelfUpdateIdentity.excludingSelf([selfApp, other]).map(\.name), ["IINA"])

        let updates = [
            AppUpdate(app: selfApp, result: .unsupported(reason: "未识别到公开的更新接口")),
            AppUpdate(app: other, result: .upToDate(latest: "1.3.5"))
        ]
        XCTAssertEqual(SelfUpdateIdentity.excludingSelf(updates).map(\.app.name), ["IINA"])
    }
}
