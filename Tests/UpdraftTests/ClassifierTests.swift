import XCTest
@testable import UpdraftKit

/// 扫描 + 分类的集成测试。直接在临时目录里造假的 .app 包，不碰真实系统。
final class ClassifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func makeApp(
        _ name: String,
        bundleID: String = "com.example.app",
        version: String = "1.0.0",
        plistExtra: [String: Any] = [:],
        files: [String] = [],
        directories: [String] = []
    ) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleDisplayName": name
        ]
        plist.merge(plistExtra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        for file in files {
            let url = contents.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        for directory in directories {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        return app
    }

    private func classify(_ apps: [String: String] = [:]) -> [String: AppInfo] {
        let scanned = AppScanner(searchPaths: [root]).scan()
        let index = BrewCaskIndex(appNameToToken: apps, installedTokens: Array(apps.values), binaryOnlyTokens: [:])
        let classifier = AppClassifier(caskIndex: index)
        var result: [String: AppInfo] = [:]
        for item in scanned {
            result[item.name] = classifier.classify(item)
        }
        return result
    }

    func testSparkleAppWithFeedURL() throws {
        try makeApp("IINA", version: "1.3.5", plistExtra: ["SUFeedURL": "https://www.iina.io/appcast.xml"])
        let apps = classify()
        guard case .sparkle(let url) = apps["IINA"]?.source else {
            return XCTFail("应识别为 Sparkle")
        }
        XCTAssertEqual(url?.absoluteString, "https://www.iina.io/appcast.xml")
        XCTAssertTrue(apps["IINA"]!.source.isAutoDetectable)
    }

    func testEmbeddedSparkleWithoutFeedIsUnsupported() throws {
        try makeApp("AltTab", directories: ["Frameworks/Sparkle.framework"])
        let apps = classify()
        guard case .unsupported(let reason) = apps["AltTab"]?.source else {
            return XCTFail("应识别为不支持")
        }
        XCTAssertTrue(reason.contains("硬编码"))
        XCTAssertFalse(apps["AltTab"]!.source.isAutoDetectable)
    }

    func testAppStoreReceiptWinsOverEverythingElse() throws {
        try makeApp("Xcode", directories: ["_MASReceipt"])
        let apps = classify()
        guard case .appStore = apps["Xcode"]?.source else {
            return XCTFail("应识别为 App Store")
        }
    }

    func testElectronApp() throws {
        try makeApp("SomeElectronApp", files: ["Resources/app-update.yml"])
        let apps = classify()
        guard case .electron = apps["SomeElectronApp"]?.source else {
            return XCTFail("应识别为 Electron")
        }
        XCTAssertTrue(apps["SomeElectronApp"]!.source.isAutoDetectable)
    }

    func testHomebrewTakesPrecedenceOverSparkle() throws {
        // Mac Mouse Fix 既是 cask 又内嵌 Sparkle，必须走 Homebrew —— 只有它能一键升完。
        try makeApp("Mac Mouse Fix", plistExtra: ["SUFeedURL": "https://example.com/appcast.xml"])
        let apps = classify(["mac mouse fix": "mac-mouse-fix"])
        guard case .homebrewCask(let token) = apps["Mac Mouse Fix"]?.source else {
            return XCTFail("应优先识别为 Homebrew cask")
        }
        XCTAssertEqual(token, "mac-mouse-fix")
    }

    func testCaskNameMismatchIsResolvedByArtifactName() throws {
        // 目录名是 easy-move+resize，包名是 Easy Move+Resize.app，靠 cask 产物名对上。
        try makeApp("Easy Move+Resize")
        let apps = classify(["easy move+resize": "easy-move+resize"])
        guard case .homebrewCask(let token) = apps["Easy Move+Resize"]?.source else {
            return XCTFail("应识别为 Homebrew cask")
        }
        XCTAssertEqual(token, "easy-move+resize")
    }

    func testProprietaryAppsCarryAReadableReason() throws {
        try makeApp("Adobe Photoshop 2026", bundleID: "com.adobe.Photoshop")
        try makeApp("Steam", bundleID: "com.valvesoftware.steam")
        try makeApp("JetBrains Toolbox", bundleID: "com.jetbrains.toolbox")

        let apps = classify()
        guard case .unsupported(let adobe) = apps["Adobe Photoshop 2026"]?.source,
              case .unsupported(let steam) = apps["Steam"]?.source,
              case .unsupported(let jetbrains) = apps["JetBrains Toolbox"]?.source else {
            return XCTFail("三个都应识别为不支持")
        }
        XCTAssertTrue(adobe.contains("Adobe"))
        XCTAssertTrue(steam.contains("Steam"))
        XCTAssertTrue(jetbrains.contains("JetBrains"))
    }

    func testUnknownAppFallsBackToGenericReason() throws {
        try makeApp("MysteryTool")
        let apps = classify()
        guard case .unsupported(let reason) = apps["MysteryTool"]?.source else {
            return XCTFail("应识别为不支持")
        }
        XCTAssertEqual(reason, "未识别到公开的更新接口")
    }

    func testScannerReadsVersionAndInitial() throws {
        try makeApp("Bob", version: "1.9.2")
        let apps = classify()
        XCTAssertEqual(apps["Bob"]?.currentVersion, "1.9.2")
        XCTAssertEqual(apps["Bob"]?.initial, "B")
    }

    func testScannerIgnoresNonAppEntries() throws {
        try makeApp("RealApp")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("NotAnApp", isDirectory: true), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("readme.txt").path, contents: Data())
        let apps = classify()
        XCTAssertEqual(Array(apps.keys), ["RealApp"])
    }
}

/// 结果分组的判定与文案。
final class AppUpdatePresentationTests: XCTestCase {
    private func makeApp(_ name: String, version: String?) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: nil,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: version,
            buildVersion: nil,
            source: .sparkle(feedURL: URL(string: "https://example.com/appcast.xml"))
        )
    }

    func testGroupingPutsFailuresWithUnsupported() {
        let failed = AppUpdate(app: makeApp("A", version: "1.0"), result: .failed(reason: "超时"))
        XCTAssertEqual(failed.group, .unsupported)
    }

    func testDetailTextForUpdateIncludesVersionsAndSize() {
        let update = AppUpdate(
            app: makeApp("IINA", version: "1.3.5"),
            result: .updateAvailable(ReleaseInfo(
                version: "1.4.4",
                downloadURL: URL(string: "https://dl.iina.io/IINA.v1.4.4.dmg"),
                size: 109_301_417
            ))
        )
        XCTAssertTrue(update.detailText.contains("1.3.5 → 1.4.4"))
        XCTAssertTrue(update.detailText.contains("Sparkle"))
        XCTAssertTrue(update.detailText.contains("MB"))
    }

    func testDetailTextOmitsSizeWhenUnknown() {
        let update = AppUpdate(
            app: makeApp("PopClip", version: "2024.1"),
            result: .updateAvailable(ReleaseInfo(version: "2024.2", downloadURL: nil))
        )
        XCTAssertFalse(update.detailText.contains("MB"))
        XCTAssertTrue(update.detailText.contains("2024.1 → 2024.2"))
    }
}
