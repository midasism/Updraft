import CryptoKit
import XCTest
@testable import AppUpdaterKit

/// appcast 里 `<sparkle:deltas>` 的回归测试。
///
/// 这是真实发生过的 bug：AlDente 的 appcast 在正式包**后面**又挂了一组增量补丁，
/// 解析器按"后写覆盖先写"处理，于是界面上显示的是补丁的地址和体积（2.3 MB），
/// 用户点下载拿到的就是一个装不了的 `.delta` 文件。这组测试守住这条边界。
final class AppcastDeltaTests: XCTestCase {
    /// 结构照抄 https://apphousekitchen.com/aldente/aldenteproappcast.xml
    private let alDenteXML = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>AlDente-Pro</title>
            <item>
                <title>1.39.2</title>
                <pubDate>Thu, 10 Sep 2026 09:43:15 +0200</pubDate>
                <sparkle:version>110</sparkle:version>
                <sparkle:shortVersionString>1.39.2</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
                <enclosure url="https://apphousekitchen.com/aldente/AlDente1.39.2.dmg" length="12206975"
                    type="application/octet-stream" sparkle:edSignature="REAL-SIGNATURE==" />
                <sparkle:deltas>
                    <enclosure url="https://apphousekitchen.com/aldente/AlDente110-109.delta" sparkle:deltaFrom="109"
                        length="548342" type="application/octet-stream" sparkle:edSignature="DELTA-SIG-1==" />
                    <enclosure url="https://apphousekitchen.com/aldente/AlDente110-105.delta" sparkle:deltaFrom="105"
                        length="2346622" type="application/octet-stream" sparkle:edSignature="DELTA-SIG-2==" />
                </sparkle:deltas>
            </item>
        </channel>
    </rss>
    """

    func testDeltaEnclosuresNeverOverwriteTheFullPackage() {
        let item = AppcastParser.parse(alDenteXML).latestItem()

        XCTAssertEqual(
            item?.downloadURL?.absoluteString,
            "https://apphousekitchen.com/aldente/AlDente1.39.2.dmg",
            "下载地址必须是完整 dmg，不能被 delta 覆盖"
        )
        XCTAssertEqual(item?.size, 12_206_975, "体积必须是完整包的大小，而不是最后一个补丁的大小")
        XCTAssertEqual(item?.edSignature, "REAL-SIGNATURE==", "签名必须是完整包的签名")
        XCTAssertEqual(item?.deltaCount, 2, "补丁数量应当被记录，但不参与下载")
    }

    func testDeltaURLIsNeverSurfacedAsDownloadTarget() {
        let item = AppcastParser.parse(alDenteXML).latestItem()
        XCTAssertNotEqual(item?.downloadURL?.pathExtension.lowercased(), "delta")
    }

    /// 补丁排在正式包**前面**也不能出错。
    func testDeltasBeforeFullPackageStillResolveToFullPackage() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:version>110</sparkle:version>
                    <sparkle:shortVersionString>1.39.2</sparkle:shortVersionString>
                    <sparkle:deltas>
                        <enclosure url="https://example.com/upgrade.delta" sparkle:deltaFrom="105" length="2346622" />
                    </sparkle:deltas>
                    <enclosure url="https://example.com/Full.dmg" length="12206975" sparkle:edSignature="SIG==" />
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parse(xml).latestItem()
        XCTAssertEqual(item?.downloadURL?.absoluteString, "https://example.com/Full.dmg")
        XCTAssertEqual(item?.size, 12_206_975)
        XCTAssertEqual(item?.edSignature, "SIG==")
    }

    /// 只有补丁、没有完整包时，必须如实给出 nil，让探针报"没有完整安装包"，
    /// 而不是把一个装不上的文件递给用户。
    func testDeltasOnlyYieldsNoDownloadURL() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:version>110</sparkle:version>
                    <sparkle:shortVersionString>1.39.2</sparkle:shortVersionString>
                    <sparkle:deltas>
                        <enclosure url="https://example.com/upgrade.delta" sparkle:deltaFrom="105" length="2346622" />
                    </sparkle:deltas>
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parse(xml).latestItem()
        XCTAssertNil(item?.downloadURL)
        XCTAssertEqual(item?.deltaCount, 1)
    }

    /// 同一 item 里有多个正式 enclosure 时，第一个胜出。
    func testFirstFullEnclosureWinsOverLaterSiblings() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:version>5</sparkle:version>
                    <enclosure url="https://example.com/A.dmg" length="1000" sparkle:edSignature="FIRST==" />
                    <enclosure url="https://example.com/A-arm64.dmg" length="2000" sparkle:edSignature="SECOND==" />
                </item>
            </channel>
        </rss>
        """
        let item = AppcastParser.parse(xml).latestItem()
        XCTAssertEqual(item?.downloadURL?.absoluteString, "https://example.com/A.dmg")
        XCTAssertEqual(item?.edSignature, "FIRST==")
    }

    /// 嵌套层级必须成对收放，否则后面的条目会静默丢掉正式包。
    func testDeltaDepthResetsBetweenItems() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <sparkle:version>2</sparkle:version>
                    <enclosure url="https://example.com/B.dmg" length="2000" />
                    <sparkle:deltas>
                        <enclosure url="https://example.com/2-1.delta" sparkle:deltaFrom="1" length="500" />
                    </sparkle:deltas>
                </item>
                <item>
                    <sparkle:version>1</sparkle:version>
                    <enclosure url="https://example.com/A.dmg" length="1000" />
                </item>
            </channel>
        </rss>
        """
        let appcast = AppcastParser.parse(xml)
        XCTAssertEqual(appcast.items.count, 2)
        XCTAssertEqual(appcast.items[0].downloadURL?.absoluteString, "https://example.com/B.dmg")
        XCTAssertEqual(
            appcast.items[1].downloadURL?.absoluteString,
            "https://example.com/A.dmg",
            "上一个条目的 deltas 不能让下一个条目的正式包被忽略"
        )
    }

    func testLatestItemPicksByBuildNumberNotDocumentOrder() {
        let item = AppcastParser.parse(alDenteXML).latestItem()
        XCTAssertEqual(item?.shortVersion, "1.39.2")
        XCTAssertEqual(item?.buildVersion, "110")
    }
}

final class PackageKindTests: XCTestCase {
    func testDetectsKindFromExtension() {
        XCTAssertEqual(PackageKind(url: URL(string: "https://x.com/a.dmg")), .dmg)
        XCTAssertEqual(PackageKind(url: URL(string: "https://x.com/a.ZIP")), .zip)
        XCTAssertEqual(PackageKind(url: URL(string: "https://x.com/a.pkg")), .pkg)
        XCTAssertEqual(PackageKind(url: URL(string: "https://x.com/a.tar.gz")), .unknown)
        XCTAssertEqual(PackageKind(url: nil), .unknown)
    }

    func testAutoInstallableSet() {
        XCTAssertTrue(PackageKind.dmg.isAutoInstallable)
        XCTAssertTrue(PackageKind.zip.isAutoInstallable)
        XCTAssertFalse(PackageKind.pkg.isAutoInstallable, ".pkg 需要管理员密码，不能自动装")
        XCTAssertFalse(PackageKind.unknown.isAutoInstallable)
    }
}

final class InstallActionTests: XCTestCase {
    private func makeApp(
        name: String = "IINA",
        bundleID: String? = "com.colliderli.iina",
        path: String = "/Applications/IINA.app",
        version: String = "1.3.5",
        source: AppSource = .sparkle(feedURL: URL(string: "https://www.iina.io/appcast.xml")),
        publicEDKey: String? = nil
    ) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            path: URL(fileURLWithPath: path),
            currentVersion: version,
            buildVersion: nil,
            source: source,
            publicEDKey: publicEDKey
        )
    }

    func testDmgOnSparkleBecomesReplaceBundle() {
        let update = AppUpdate(
            app: makeApp(),
            result: .updateAvailable(ReleaseInfo(version: "1.4.4", downloadURL: URL(string: "https://dl.iina.io/IINA.v1.4.4.dmg")))
        )
        XCTAssertEqual(update.installAction, .replaceBundle)
        XCTAssertTrue(update.installAction.isAutomated)
    }

    func testZipIsAlsoAutoInstallable() {
        let update = AppUpdate(
            app: makeApp(name: "Mac Mouse Fix", bundleID: "com.nuebling.mac-mouse-fix", path: "/Applications/Mac Mouse Fix.app"),
            result: .updateAvailable(ReleaseInfo(version: "3.0.0", downloadURL: URL(string: "https://example.com/a.zip")))
        )
        XCTAssertEqual(update.installAction, .replaceBundle)
    }

    func testPkgNeedsTheSystemInstaller() {
        let update = AppUpdate(
            app: makeApp(name: "ToDesk", bundleID: "com.youqu.todesk", path: "/Applications/ToDesk.app"),
            result: .updateAvailable(ReleaseInfo(version: "5.0.0", downloadURL: URL(string: "https://example.com/a.pkg")))
        )
        XCTAssertEqual(update.installAction, .openInstaller)
        XCTAssertFalse(update.installAction.isAutomated)
    }

    func testHomebrewAlwaysWinsOverSparkle() {
        // mac-mouse-fix 同时是 cask 和 Sparkle 应用；只有 Homebrew 那条路能真正一键升完。
        let update = AppUpdate(
            app: makeApp(
                name: "Mac Mouse Fix",
                path: "/Applications/Mac Mouse Fix.app",
                source: .homebrewCask(token: "mac-mouse-fix")
            ),
            result: .updateAvailable(ReleaseInfo(version: "3.0.0", downloadURL: URL(string: "https://example.com/a.zip")))
        )
        XCTAssertEqual(update.installAction, .homebrew(token: "mac-mouse-fix"))
    }

    func testMissingBundleIDFallsBackToOpenDownload() {
        let update = AppUpdate(
            app: makeApp(bundleID: nil),
            result: .updateAvailable(ReleaseInfo(version: "1.4.4", downloadURL: URL(string: "https://dl.iina.io/IINA.v1.4.4.dmg")))
        )
        XCTAssertEqual(update.installAction, .openDownload, "确认不了包身份就不能自动替换")
    }

    func testAppOutsideApplicationsIsNotReplaceable() {
        let update = AppUpdate(
            app: makeApp(path: "/Users/someone/Downloads/IINA.app"),
            result: .updateAvailable(ReleaseInfo(version: "1.4.4", downloadURL: URL(string: "https://dl.iina.io/x.dmg")))
        )
        XCTAssertEqual(update.installAction, .openDownload)
    }

    func testReplaceablePathRules() {
        XCTAssertTrue(AppUpdate.isReplaceable(URL(fileURLWithPath: "/Applications/IINA.app")))
        // 允许把 /Applications 分文件夹整理。
        XCTAssertTrue(AppUpdate.isReplaceable(URL(fileURLWithPath: "/Applications/Utilities/Console.app")))
        // 系统应用永远不碰。
        XCTAssertFalse(AppUpdate.isReplaceable(URL(fileURLWithPath: "/System/Applications/Safari.app")))
        // 不是 .app 包。
        XCTAssertFalse(AppUpdate.isReplaceable(URL(fileURLWithPath: "/Applications/IINA")))
        // 用户目录下的散包不在范围内。
        XCTAssertFalse(AppUpdate.isReplaceable(URL(fileURLWithPath: "/Users/x/Downloads/IINA.app")))
        // 嵌在另一个 .app 内部的包，语义不明，不碰。
        XCTAssertFalse(AppUpdate.isReplaceable(URL(fileURLWithPath: "/Applications/Outer.app/Contents/Helpers/Inner.app")))
    }

    func testDeltaDownloadURLIsNotOfferedForReplacement() {
        // 万一解析层漏了，动作层也要把 .delta 拦在自动安装之外。
        let update = AppUpdate(
            app: makeApp(),
            result: .updateAvailable(ReleaseInfo(version: "1.4.4", downloadURL: URL(string: "https://x.com/u.delta")))
        )
        XCTAssertEqual(update.installAction, .openDownload)
    }

    func testUpToDateHasNoAction() {
        let update = AppUpdate(app: makeApp(), result: .upToDate(latest: "1.3.5"))
        XCTAssertEqual(update.installAction, .manual)
        XCTAssertEqual(update.installAction.buttonTitle, "—")
    }
}

final class SignatureVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ bytes: Data, name: String = "package.dmg") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// 正面用例：用真实 Ed25519 密钥对签名，必须校验通过。
    func testAcceptsGenuineSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("this stands in for a 12 MB dmg".utf8)
        let file = try write(payload)

        let outcome = SignatureVerifier.verify(
            fileAt: file,
            signatureBase64: try key.signature(for: payload).base64EncodedString(),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertEqual(outcome, .verified)
        XCTAssertTrue(outcome.isVerified)
        XCTAssertFalse(outcome.isFailure)
    }

    func testRejectsTamperedPayload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("original installer bytes".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()

        // 内容被改了一个字节——这正是恶意替换安装包的样子。
        let tampered = try write(Data("original installer byteS".utf8))
        let outcome = SignatureVerifier.verify(
            fileAt: tampered,
            signatureBase64: signature,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure, "内容被篡改必须判为失败")
    }

    func testRejectsSignatureFromAnotherKey() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let payload = Data("installer".utf8)
        let file = try write(payload)

        let outcome = SignatureVerifier.verify(
            fileAt: file,
            signatureBase64: try signer.signature(for: payload).base64EncodedString(),
            publicKeyBase64: impostor.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure, "换了公钥必须判为失败")
    }

    func testSkipsWhenAppPublishesNoKey() throws {
        let file = try write(Data("x".utf8))
        let outcome = SignatureVerifier.verify(fileAt: file, signatureBase64: "AAAA", publicKeyBase64: nil)
        XCTAssertEqual(outcome, .skipped(reason: "该应用未公布签名公钥"))
        XCTAssertFalse(outcome.isFailure, "缺少公钥是能力缺失，不是校验失败")
    }

    func testSkipsWhenFeedProvidesNoSignature() throws {
        let file = try write(Data("x".utf8))
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let outcome = SignatureVerifier.verify(fileAt: file, signatureBase64: nil, publicKeyBase64: key)
        XCTAssertEqual(outcome, .skipped(reason: "更新源未提供签名"))
    }

    func testRejectsMalformedKeyOrSignature() throws {
        let file = try write(Data("x".utf8))
        let badKey = Data(repeating: 1, count: 8).base64EncodedString()
        let goodKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let badSignature = Data(repeating: 2, count: 8).base64EncodedString()

        XCTAssertTrue(SignatureVerifier.verify(fileAt: file, signatureBase64: badSignature, publicKeyBase64: badKey).isFailure)
        XCTAssertTrue(SignatureVerifier.verify(fileAt: file, signatureBase64: badSignature, publicKeyBase64: goodKey).isFailure)
    }

    func testReportsMissingFileAsFailure() {
        let outcome = SignatureVerifier.verify(
            fileAt: directory.appendingPathComponent("does-not-exist.dmg"),
            signatureBase64: Data(repeating: 3, count: 64).base64EncodedString(),
            publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(outcome.isFailure)
    }
}

final class BackupStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func makeFakeApp(name: String, marker: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker.txt"))
        return app.deletingLastPathComponent()
    }

    func testBackupCopiesBundleVerbatim() async throws {
        let app = try makeFakeApp(name: "Demo", marker: "v1")
        let store = BackupStore(root: root.appendingPathComponent("Backups"))

        let path = try await store.backup(appAt: app, name: "Demo", version: "1.0", bundleID: "com.example.demo")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let marker = try String(contentsOf: path.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "v1")
        XCTAssertTrue(path.lastPathComponent == "Demo.app")
        XCTAssertTrue(path.path.contains("com.example.demo"))
    }

    func testPruneKeepsOnlyTheMostRecent() async throws {
        let app = try makeFakeApp(name: "Demo", marker: "v1")
        let store = BackupStore(root: root.appendingPathComponent("Backups"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in 0..<3 {
            try await store.backup(
                appAt: app,
                name: "Demo",
                version: "1.\(offset)",
                bundleID: "com.example.demo",
                date: base.addingTimeInterval(Double(offset) * 3600)
            )
        }

        let removed = store.prune(bundleID: "com.example.demo", keeping: 1)
        XCTAssertEqual(removed.count, 2, "三份备份保留一份，应删掉两份")

        let container = root.appendingPathComponent("Backups/com.example.demo")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: container.path)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].hasSuffix("1.2"), "留下的应当是最新那份")
    }

    func testPruneOnUnknownBundleIsHarmless() {
        let store = BackupStore(root: root.appendingPathComponent("Backups"))
        XCTAssertTrue(store.prune(bundleID: "com.example.nothing", keeping: 1).isEmpty)
    }

    func testBundleIDIsSanitizedForFilesystem() {
        XCTAssertEqual(BackupStore.sanitized("com.example.app"), "com.example.app")
        XCTAssertEqual(BackupStore.sanitized("a/b"), "a_b")
        XCTAssertEqual(BackupStore.sanitized("   "), "unknown")
        XCTAssertEqual(BackupStore.sanitized(""), "unknown")
    }

    /// 时间戳的字典序必须等于时间序，否则清理逻辑会删错备份。
    func testTimestampSortsChronologically() {
        let earlier = BackupStore.timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let later = BackupStore.timestamp(Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertLessThan(earlier, later)
        XCTAssertEqual(earlier.count, later.count, "定长才能保证字典序稳定")
    }
}

final class UpgradeJobTests: XCTestCase {
    private func item(_ name: String, automated: Bool) -> UpgradeJob.Item {
        let app = AppInfo(
            name: name,
            bundleID: "com.example.\(name)",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: automated ? .sparkle(feedURL: nil) : .unsupported(reason: "x")
        )
        let action: InstallAction = automated ? .replaceBundle : .openDownload
        let plan = automated
            ? Installer().makePlan(app: app, release: ReleaseInfo(version: "2.0"))
            : nil
        return UpgradeJob.Item(app: app, release: ReleaseInfo(version: "2.0"), action: action, plan: plan)
    }

    func testSingleItemTitleUsesAppName() {
        let job = UpgradeJob(items: [item("IINA", automated: true)])
        XCTAssertEqual(job.title, "升级 IINA")
        XCTAssertEqual(job.automatedCount, 1)
    }

    func testBatchTitleCountsItems() {
        let job = UpgradeJob(items: [item("A", automated: true), item("B", automated: true)])
        XCTAssertEqual(job.title, "批量升级 2 个应用")
    }

    func testOutcomeTallies() {
        var job = UpgradeJob(items: [item("A", automated: true), item("B", automated: true)])
        job.outcomes = [
            UpgradeJob.Outcome(id: "1", appName: "A", fromVersion: "1.0", toVersion: "2.0",
                               succeeded: true, summary: "", backupPath: nil, rolledBack: false,
                               warnings: [], log: ""),
            UpgradeJob.Outcome(id: "2", appName: "B", fromVersion: "1.0", toVersion: "2.0",
                               succeeded: false, summary: "失败", backupPath: nil, rolledBack: true,
                               warnings: [], log: "")
        ]
        XCTAssertEqual(job.succeededCount, 1)
        XCTAssertEqual(job.failedCount, 1)
    }

    func testItemStateTerminality() {
        XCTAssertFalse(UpgradeJob.ItemState.pending.isTerminal)
        XCTAssertFalse(UpgradeJob.ItemState.running.isTerminal)
        XCTAssertTrue(UpgradeJob.ItemState.succeeded.isTerminal)
        XCTAssertTrue(UpgradeJob.ItemState.failed("x").isTerminal)
        XCTAssertTrue(UpgradeJob.ItemState.skipped("x").isTerminal)
    }
}

/// 安装流程被强杀后的恢复。
///
/// 这套逻辑守的是最坏情况：`swapIn` 的三步之间进程死掉，
/// `/Applications` 里会留下隐藏的中间态文件，甚至应用本身消失。
/// 恢复必须既能收拾干净，又不能把用户唯一的一份应用删掉。
final class InterruptedInstallRecoveryTests: XCTestCase {
    private var root: URL!
    private let token = "38144E15"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// 造一个"健康"的 .app：Info.plist 齐备，可执行文件存在。
    @discardableResult
    private func makeBundle(at url: URL, bundleID: String = "io.github.keycastr", version: String = "0.11.1") throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "KeyCastr",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("KeyCastr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("KeyCastr").path)
        return url
    }

    private func artifact(_ kind: String, stem: String = "KeyCastr") -> URL {
        root.appendingPathComponent(".\(stem).\(token).\(kind).app", isDirectory: true)
    }

    // MARK: 文件名识别

    func testClassifiesOurOwnArtifacts() {
        XCTAssertEqual(Installer.classifyArtifact(".KeyCastr.38144E15.old.app")?.stem, "KeyCastr")
        XCTAssertEqual(Installer.classifyArtifact(".KeyCastr.38144E15.old.app")?.kind, .displaced)
        XCTAssertEqual(Installer.classifyArtifact(".KeyCastr.38144E15.new.app")?.kind, .incoming)
        XCTAssertEqual(Installer.classifyArtifact(".KeyCastr.app.broken-38144E15")?.kind, .broken)
    }

    /// 名字里带点的应用（`Foo.bar.app`）也要能正确还原目标名。
    func testHandlesStemsContainingDots() {
        XCTAssertEqual(Installer.classifyArtifact(".Foo.bar.38144E15.old.app")?.stem, "Foo.bar")
    }

    func testIgnoresFilesThatAreNotOurs() {
        for name in [".DS_Store", ".hidden", "._KeyCastr.38144E15.old.app",
                     ".KeyCastr.old.app",              // 缺 token
                     ".KeyCastr.zzzzzzzz.old.app",     // token 不是十六进制
                     ".KeyCastr.38144E1.old.app",      // token 长度不对
                     "KeyCastr.38144E15.old.app",      // 没有前导点
                     ".KeyCastr"] {
            XCTAssertNil(Installer.classifyArtifact(name), "\(name) 不该被当成安装残留")
        }
    }

    // MARK: 恢复行为

    /// 换包已经完成、只是没来得及删除旧包：目标完好，残留直接清掉。
    func testRemovesArtifactsWhenTargetIsHealthy() throws {
        try makeBundle(at: root.appendingPathComponent("KeyCastr.app"))
        try makeBundle(at: artifact("old"), version: "0.10.3")

        let report = Installer.recoverInterruptedInstalls(in: [root])

        XCTAssertTrue(report.rescuedApps.isEmpty)
        XCTAssertEqual(report.removedArtifacts, [".KeyCastr.\(token).old.app"])
        XCTAssertTrue(report.needsAttention.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact("old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("KeyCastr.app").path))
    }

    /// 崩溃落在"旧包已挪走、新包未就位"之间：应用从 /Applications 消失了，
    /// 必须把旧包搬回去，而不是顺手删掉。
    func testRescuesAppWhenTargetIsMissing() throws {
        try makeBundle(at: artifact("old"), version: "0.10.3")

        let report = Installer.recoverInterruptedInstalls(in: [root])

        XCTAssertEqual(report.rescuedApps, ["KeyCastr"])
        let restored = root.appendingPathComponent("KeyCastr.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path), "应用必须被救回来")
        XCTAssertEqual(Installer.plistValue("CFBundleShortVersionString", in: restored), "0.10.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact("old").path))
        XCTAssertTrue(report.needsAttention.isEmpty)
    }

    /// 目标存在但已损坏（比如只拷了一半），同样应该用旧包顶上去。
    func testRescuesWhenTargetIsCorrupt() throws {
        // 只有一个空壳目录，没有 Info.plist
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("KeyCastr.app"),
            withIntermediateDirectories: true
        )
        try makeBundle(at: artifact("old"), version: "0.10.3")

        let report = Installer.recoverInterruptedInstalls(in: [root])

        XCTAssertEqual(report.rescuedApps, ["KeyCastr"])
        let restored = root.appendingPathComponent("KeyCastr.app")
        XCTAssertEqual(Installer.plistValue("CFBundleShortVersionString", in: restored), "0.10.3")
    }

    /// 目标缺失又没有可用的旧包：什么都不删，如实上报等人处理。
    /// 这种情况下的删除是不可逆的数据损失。
    func testKeepsArtifactsAndReportsWhenNothingCanRescue() throws {
        try makeBundle(at: artifact("new"))

        let report = Installer.recoverInterruptedInstalls(in: [root])

        XCTAssertTrue(report.rescuedApps.isEmpty)
        XCTAssertTrue(report.removedArtifacts.isEmpty, "没有可用的旧包时绝不能删东西")
        XCTAssertEqual(report.needsAttention.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact("new").path), "残留必须原样保留")
    }

    /// 空目录（没有 .app）是无害的，不该报错也不该动它。
    func testDoesNothingWhenClean() throws {
        let report = Installer.recoverInterruptedInstalls(in: [root])
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.summary.isEmpty)
    }

    func testSummaryDescribesWhatHappened() throws {
        try makeBundle(at: root.appendingPathComponent("KeyCastr.app"))
        try makeBundle(at: artifact("old"), version: "0.10.3")
        try makeBundle(at: artifact("new"), version: "0.11.1")

        let report = Installer.recoverInterruptedInstalls(in: [root])
        XCTAssertEqual(report.removedArtifacts.count, 2)
        XCTAssertTrue(report.summary.contains("清理了 2 个残留文件"))
    }

    func testHealthyBundleCheck() throws {
        let good = try makeBundle(at: root.appendingPathComponent("Good.app"))
        XCTAssertTrue(Installer.isHealthyBundle(good))

        let empty = root.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(Installer.isHealthyBundle(empty), "没有 Info.plist 不算完好的包")
        XCTAssertFalse(Installer.isHealthyBundle(root.appendingPathComponent("Nope.app")))
    }
}

final class InstallerHelpersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func makeApp(_ name: String, bundleID: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": "2.0",
            "CFBundleName": name
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testFindAppBundleMatchesBundleIdentifier() throws {
        _ = try makeApp("Other", bundleID: "com.example.other")
        let wanted = try makeApp("Target", bundleID: "com.example.target")

        let found = Installer.findAppBundle(in: root, matching: "com.example.target")
        XCTAssertEqual(found?.standardizedFileURL.path, wanted.standardizedFileURL.path)
    }

    /// dmg 里常有一个指向 /Applications 的软链；顺着它走会匹配到本机已装的自己。
    func testFindAppBundleSkipsSymlinks() throws {
        _ = try makeApp("Real", bundleID: "com.example.real")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Applications"),
            withDestinationURL: URL(fileURLWithPath: "/Applications")
        )

        let found = Installer.findAppBundle(in: root, matching: "com.example.real")
        XCTAssertEqual(found?.lastPathComponent, "Real.app")
        XCTAssertFalse(found?.path.hasPrefix("/Applications/") == true, "绝不能匹配到 /Applications 里的应用")
    }

    func testFindAppBundleFallsBackToSoleBundle() throws {
        let only = try makeApp("Solo", bundleID: "com.example.solo")
        let found = Installer.findAppBundle(in: root, matching: "com.example.does-not-match")
        XCTAssertEqual(found?.standardizedFileURL.path, only.standardizedFileURL.path)
    }

    func testFindAppBundleReturnsNilWhenAmbiguous() throws {
        _ = try makeApp("A", bundleID: "com.example.a")
        _ = try makeApp("B", bundleID: "com.example.b")
        XCTAssertNil(Installer.findAppBundle(in: root, matching: "com.example.unknown"))
    }

    func testAttachedDeviceParsing() {
        let output = """
        /dev/disk4          	Apple_partition_scheme
        /dev/disk4s1        	Apple_HFS                      	/Volumes/AlDente
        """
        XCTAssertEqual(Installer.attachedDevice(in: output), "/dev/disk4")
        XCTAssertNil(Installer.attachedDevice(in: "hdiutil: attach failed - no mountable file systems"))
    }

    func testPlanReportsSignatureAvailability() {
        let installer = Installer()
        let withoutKey = AppInfo(
            name: "AlDente",
            bundleID: "com.apphousekitchen.aldente-pro",
            path: URL(fileURLWithPath: "/Applications/AlDente.app"),
            currentVersion: "1.29",
            buildVersion: nil,
            source: .sparkle(feedURL: nil)
        )
        let plan = installer.makePlan(app: withoutKey, release: ReleaseInfo(version: "1.39.2", size: 12_000_000))
        if case .cannotVerify = plan.signature {} else {
            XCTFail("没有公钥时应如实报告无法校验")
        }
        XCTAssertTrue(plan.warnings.contains { $0.contains("未公布签名公钥") })

        let withKey = AppInfo(
            name: "IINA",
            bundleID: "com.colliderli.iina",
            path: URL(fileURLWithPath: "/Applications/IINA.app"),
            currentVersion: "1.3.5",
            buildVersion: nil,
            source: .sparkle(feedURL: nil),
            publicEDKey: "AAAA"
        )
        let verifiedPlan = installer.makePlan(app: withKey, release: ReleaseInfo(version: "1.4.4", size: 109_000_000))
        XCTAssertEqual(verifiedPlan.signature, .willVerify)
    }

    /// 体积明显小于现有应用包，是"拿到的不是完整包"的信号（增量补丁正是这样），预检就该提示。
    func testPlanWarnsWhenPackageIsFarSmallerThanInstalledApp() throws {
        let installed = root.appendingPathComponent("AlDente.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1_000_000)
            .write(to: installed.appendingPathComponent("blob.bin"))

        let app = AppInfo(
            name: "AlDente",
            bundleID: "com.apphousekitchen.aldente-pro",
            path: installed,
            currentVersion: "1.29",
            buildVersion: nil,
            source: .sparkle(feedURL: nil)
        )

        // 现有包约 1 MB，安装包只有 200 KB —— 典型的增量补丁比例。
        let suspicious = Installer().makePlan(app: app, release: ReleaseInfo(version: "1.39.2", size: 200_000))
        XCTAssertTrue(suspicious.warnings.contains { $0.contains("可能不是完整包") })

        // 同体积量级的正常包不该被误报。
        let normal = Installer().makePlan(app: app, release: ReleaseInfo(version: "1.39.2", size: 900_000))
        XCTAssertFalse(normal.warnings.contains { $0.contains("可能不是完整包") })
    }
}

/// 「全部升级」只该动传进来的那批。
///
/// 这条边界靠读代码守不住：搜索框有词时，参数传错的话用户筛出 1 个却升了全量，
/// 而界面上一个提示都不会有。
final class AutomatedCandidateTests: XCTestCase {
    private func update(_ name: String, source: AppSource, result: UpdateResult) -> AppUpdate {
        let app = AppInfo(
            name: name,
            bundleID: "com.example.\(name.lowercased())",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: source
        )
        return AppUpdate(app: app, result: result)
    }

    private func available() -> UpdateResult {
        .updateAvailable(
            ReleaseInfo(version: "2.0", downloadURL: URL(string: "https://example.com/A.dmg")!)
        )
    }

    func testOnlyAutoInstallableEntriesArePicked() {
        let batch = [
            update("Sparkle 可换包", source: .sparkle(feedURL: nil), result: available()),
            update("仓库里的", source: .homebrewCask(token: "x"), result: available()),
            update("已是最新", source: .sparkle(feedURL: nil), result: .upToDate(latest: "1.0")),
            update("AppStore 的", source: .appStore, result: available())
        ]

        XCTAssertEqual(
            UpdateStore.automatedCandidates(in: batch).map(\.app.name),
            ["Sparkle 可换包", "仓库里的"],
            "已是最新与 App Store 的都不该进批量任务"
        )
    }

    func testEmptyInputYieldsEmptySelection() {
        XCTAssertTrue(UpdateStore.automatedCandidates(in: []).isEmpty)
    }

    func testPkgOnlyEntryIsNotAutomated() {
        let pkg = update(
            "pkg 应用",
            source: .sparkle(feedURL: nil),
            result: .updateAvailable(
                ReleaseInfo(version: "2.0", downloadURL: URL(string: "https://example.com/A.pkg")!)
            )
        )
        XCTAssertTrue(
            UpdateStore.automatedCandidates(in: [pkg]).isEmpty,
            ".pkg 需要管理员密码，只能交给系统安装器"
        )
    }
}
