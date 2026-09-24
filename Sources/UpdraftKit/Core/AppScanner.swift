import Foundation
import OSLog

/// 扫描阶段读到的原始事实。分类器只依赖这里暴露的字段，不再碰文件系统。
public struct ScannedApp: Sendable {
    public let name: String
    public let bundleID: String?
    public let path: URL
    public let currentVersion: String?
    public let buildVersion: String?
    public let feedURLString: String?
    public let publicEDKey: String?
    public let hasMASReceipt: Bool
    public let hasEmbeddedSparkle: Bool
    public let appUpdateYML: URL?
}

/// 遍历 `/Applications` 与 `~/Applications`，读取每个 `.app` 的 Info.plist 与包内特征文件。
public struct AppScanner: Sendable {
    public static var defaultSearchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications")
        ]
    }

    private let searchPaths: [URL]

    public init(searchPaths: [URL] = AppScanner.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    public func scan() -> [ScannedApp] {
        Log.scan.info("开始扫描应用，搜索路径: \(searchPaths.map(\.lastPathComponent).joined(separator: ", "))")
        var found: [ScannedApp] = []
        var seen = Set<String>()

        for root in searchPaths {
            for appURL in appBundles(in: root) {
                let key = appURL.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                found.append(inspect(appURL))
            }
        }

        let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Log.scan.info("扫描完成，发现 \(sorted.count) 个应用")
        return sorted
    }

    /// 只读一个包。增量刷新用它替代整目录扫描。
    ///
    /// 路径不再是可用的 `.app` 目录时返回 `nil`（包被删掉、被换成文件、被挪走），
    /// 调用方必须如实处理这种情况，而不是伪造一个空条目糊过去。
    public func inspect(bundleAt appURL: URL) -> ScannedApp? {
        var isDirectory: ObjCBool = false
        guard appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return inspect(appURL)
    }

    private func appBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { url in
            guard url.pathExtension == "app" else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
    }

    private func inspect(_ appURL: URL) -> ScannedApp {
        let fm = FileManager.default
        let contents = appURL.appendingPathComponent("Contents")
        let plist = loadPlist(contents.appendingPathComponent("Info.plist"))

        let name = plist["CFBundleDisplayName"]
            ?? plist["CFBundleName"]
            ?? appURL.deletingPathExtension().lastPathComponent

        let frameworks = contents.appendingPathComponent("Frameworks")
        let hasEmbeddedSparkle = fm.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path)
            || fm.fileExists(atPath: frameworks.appendingPathComponent("Autoupdate.app").path)

        let updateYML = contents.appendingPathComponent("Resources/app-update.yml")

        return ScannedApp(
            name: name,
            bundleID: plist["CFBundleIdentifier"],
            path: appURL,
            currentVersion: plist["CFBundleShortVersionString"],
            buildVersion: plist["CFBundleVersion"],
            feedURLString: plist["SUFeedURL"],
            publicEDKey: plist["SUPublicEDKey"],
            hasMASReceipt: fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt").path),
            hasEmbeddedSparkle: hasEmbeddedSparkle,
            appUpdateYML: fm.fileExists(atPath: updateYML.path) ? updateYML : nil
        )
    }

    /// 只取字符串型字段——分类与展示需要的键都是字符串，省掉一层类型体操。
    private func loadPlist(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String:
                result[key] = string
            case let number as NSNumber:
                result[key] = number.stringValue
            case let array as [Any]:
                if let first = array.first as? String { result[key] = first }
            default:
                break
            }
        }
        return result
    }
}
