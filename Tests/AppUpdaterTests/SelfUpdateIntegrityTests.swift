import XCTest
@testable import AppUpdaterKit

/// 自更新的校验和判定。
///
/// 四种结局全部覆盖：一致、不一致、摘要文件里没有这一行、压根没提供。
/// 这些分支在"网络一切正常"时最不容易被发现，而其中的"不一致"恰恰是必须中止的那一种。
final class SelfUpdateChecksumTests: XCTestCase {
    private let zipDigest = "c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b"

    private func makeRelease(checksumURL: URL? = nil, apiDigest: String? = nil, name: String = "Updraft-0.2.1-macOS.zip") -> SelfUpdateRelease {
        SelfUpdateRelease(
            version: "0.2.1",
            tag: "v0.2.1",
            assetName: name,
            downloadURL: URL(string: "https://example.com/\(name)")!,
            packageKind: .zip,
            size: 1_104_320,
            checksumURL: checksumURL,
            apiDigest: apiDigest
        )
    }

    private let sumsText = """
    9fb6b4d1bbf1240d2052e14c4562f1ccbc8192138602c733b16d3b859f46ff4f  Updraft-0.2.1-macOS.dmg
    c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b  Updraft-0.2.1-macOS.zip
    """

    func testMatchingDigestFromChecksumFileIsVerified() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(checksumURL: URL(string: "https://example.com/SHA256SUMS.txt")),
            sumsText: sumsText
        )
        XCTAssertEqual(outcome, .verified(source: "SHA256SUMS.txt"))
    }

    /// 对不上必须中止。这是唯一一种"下载到的东西不是官方那份"的直接证据。
    func testMismatchedDigestFails() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: String(repeating: "a", count: 64),
            release: makeRelease(checksumURL: URL(string: "https://example.com/SHA256SUMS.txt")),
            sumsText: sumsText
        )
        XCTAssertEqual(outcome, .failed(reason: "与 SHA256SUMS.txt 记录的摘要不一致"))
        XCTAssertTrue(outcome.isFailure)
    }

    /// 摘要文件在、但没有这个包的行：别急着下结论，先落到 API 摘要那一步。
    func testFallsBackToAPIDigestWhenChecksumFileLacksTheAsset() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(apiDigest: "sha256:\(zipDigest)", name: "Updraft-0.3.0-macOS.zip"),
            sumsText: sumsText
        )
        XCTAssertEqual(outcome, .verified(source: "GitHub 接口摘要"))
    }

    /// API 摘要是不区分大小写的十六进制，别因为大小写差异误判成"被篡改"。
    func testAPIDigestComparisonIsCaseInsensitive() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(apiDigest: "sha256:" + zipDigest.uppercased(), name: "Updraft-0.3.0-macOS.zip"),
            sumsText: nil
        )
        XCTAssertEqual(outcome, .verified(source: "GitHub 接口摘要"))
    }

    func testMismatchedAPIDigestFails() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(apiDigest: "sha256:" + String(repeating: "b", count: 64)),
            sumsText: nil
        )
        XCTAssertTrue(outcome.isFailure)
    }

    /// 什么校验和都拿不到时是"未校验"而不是"失败"——没有依据不等于有反证。
    /// 界面上必须如实这么标，但也不能因此拒绝安装（代码签名与包身份还在）。
    func testNoChecksumAtAllIsSkippedNotFailed() {
        let outcome = SelfUpdater.evaluateChecksum(actual: zipDigest, release: makeRelease(), sumsText: nil)
        XCTAssertFalse(outcome.isFailure)
        guard case .skipped(let reason) = outcome else { return XCTFail("应当是未校验") }
        XCTAssertTrue(reason.contains("未提供校验和"))
    }

    func testChecksumFileWithoutTheAssetIsExplained() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(checksumURL: URL(string: "https://example.com/SHA256SUMS.txt"), name: "Updraft-9.9.9-macOS.zip"),
            sumsText: sumsText
        )
        guard case .skipped(let reason) = outcome else { return XCTFail("应当是未校验") }
        XCTAssertTrue(reason.contains("Updraft-9.9.9-macOS.zip"))
    }

    /// API 里出现过 `sha256:` 之外的前缀（历史上只有这一种，但不能猜）。
    func testUnknownDigestAlgorithmIsNotGuessed() {
        let outcome = SelfUpdater.evaluateChecksum(
            actual: zipDigest,
            release: makeRelease(apiDigest: "md5:abcdef"),
            sumsText: nil
        )
        XCTAssertFalse(outcome.isFailure)
        XCTAssertFalse(outcome.isVerified)
    }

    func testSha256HelperMatchesTheKnownDigestOfAbc() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha256-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)

        XCTAssertEqual(
            SelfUpdater.sha256Hex(ofFileAt: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSha256HelperReturnsNilForMissingFiles() {
        XCTAssertNil(SelfUpdater.sha256Hex(ofFileAt: URL(fileURLWithPath: "/no/such/file")))
    }
}

/// 哪些位置允许被原地替换。
///
/// 这条判定是自更新唯一的"刹车"。判宽了会把用户从 dmg 里运行的副本、
/// 甚至嵌套在别的应用里的包换掉；判严了则开发时没法验证整条链路。
final class SelfUpdateReplaceablePathTests: XCTestCase {
    func testRejectsSystemApplications() {
        XCTAssertFalse(SelfIdentity.canReplace(URL(fileURLWithPath: "/System/Applications/Mail.app")))
    }

    /// 从 dmg 里直接运行是最常见的一种：那是只读卷，换包必然失败。
    func testRejectsAnythingOnAMountedVolume() {
        XCTAssertFalse(SelfIdentity.canReplace(URL(fileURLWithPath: "/Volumes/Updraft/AppUpdater.app")))
    }

    /// 嵌在别的 .app 内部的包，"替换"这件事的语义是不成立的。
    func testRejectsNestedBundles() {
        XCTAssertFalse(SelfIdentity.canReplace(
            URL(fileURLWithPath: "/Applications/Outer.app/Contents/Helpers/AppUpdater.app")
        ))
    }

    func testRejectsPathsThatAreNotBundles() {
        XCTAssertFalse(SelfIdentity.canReplace(URL(fileURLWithPath: "/Applications")))
        XCTAssertFalse(SelfIdentity.canReplace(URL(fileURLWithPath: "/tmp/AppUpdater")))
    }

    /// 开发目录里的构建产物也要能升——否则整条链路在真机上没法验证。
    /// 这正是它比 `AppUpdate.isReplaceable` 宽一点的原因。
    func testAcceptsAWritableBundleAnywhereElse() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("replaceable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = parent.appendingPathComponent("AppUpdater.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertTrue(SelfIdentity.canReplace(app))
    }

    func testAcceptsTheStandardInstallLocation() {
        // /Applications 对本机管理员账号是可写的；不可写时这条会失败，
        // 而那恰好也是"能不能原地替换"的真实答案。
        XCTAssertEqual(
            SelfIdentity.canReplace(URL(fileURLWithPath: "/Applications/AppUpdater.app")),
            FileManager.default.isWritableFile(atPath: "/Applications")
        )
    }
}

/// 本应用不该出现在自己扫出来的列表里。
final class SelfExclusionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfExclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func makeApp(_ name: String, bundleID: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleDisplayName": name
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testScannerSkipsTheAppItselfByDefault() throws {
        try makeApp("AppUpdater", bundleID: SelfIdentity.bundleIdentifier)
        try makeApp("IINA", bundleID: "com.colliderli.iina")

        let names = AppScanner(searchPaths: [root]).scan().map(\.name)
        XCTAssertEqual(names, ["IINA"])
    }

    /// 排除是"排除自己"而不是"排除一切"：关掉之后它照样能被扫到，
    /// 否则这个过滤就会悄悄吃掉真实的条目。
    func testScannerCanBeToldToIncludeEverything() throws {
        try makeApp("AppUpdater", bundleID: SelfIdentity.bundleIdentifier)
        try makeApp("IINA", bundleID: "com.colliderli.iina")

        let names = AppScanner(searchPaths: [root], excludedBundleIDs: []).scan().map(\.name)
        XCTAssertEqual(names, ["AppUpdater", "IINA"])
    }

    /// 增量刷新走的是 `inspect(bundleAt:)`，那条路也要一致地排除自己，
    /// 否则升级收尾时它会又冒出来。
    func testSingleBundleInspectionAlsoSkipsTheAppItself() throws {
        let selfApp = try makeApp("AppUpdater", bundleID: SelfIdentity.bundleIdentifier)
        let other = try makeApp("IINA", bundleID: "com.colliderli.iina")
        let scanner = AppScanner(searchPaths: [root])

        XCTAssertNil(scanner.inspect(bundleAt: selfApp))
        XCTAssertEqual(scanner.inspect(bundleAt: other)?.bundleID, "com.colliderli.iina")
    }
}
