import Foundation

/// Updraft 自己的身份：Bundle ID、GitHub 仓库、Ed25519 公钥。
///
/// 公钥与 CI secret `UPDRAFT_ED25519_PRIVATE_KEY` 是一对。
/// 私钥只存在 GitHub Actions secret 里，不进仓库。
public enum SelfUpdateIdentity {
    public static let bundleID = "com.local.updraft"
    public static let appFileName = "Updraft.app"
    public static let displayName = "Updraft"
    public static let githubOwner = "midasism"
    public static let githubRepo = "Updraft"
    /// Ed25519 公钥（raw 32 字节，base64）。对应 CI secret `UPDRAFT_ED25519_PRIVATE_KEY`。
    public static let publicEDKey = "cEVR8yn/kKr4xV38t8A54sur94877mr01gi51IUfS10="

    /// `~/Library/Application Support/<这个名字>/`（备份与状态缓存）
    /// 与 `~/Library/Caches/<这个名字>/`（换包工作区共用一层）。
    public static let supportDirectoryName = "Updraft"

    /// 设置的 UserDefaults suite 名。**必须与 `bundleID` 不同**，所以加了后缀。
    ///
    /// macOS 拒绝「拿自己的 bundle id 当 suite 名」：`UserDefaults(suiteName:)` 直接返回
    /// nil，只在控制台留一行
    /// "Using your own bundle identifier as an NSUserDefaults suite name does not make
    ///  sense and will not work"。踩上去的后果**全是静默的**：
    ///
    /// - 读值拿到 nil → 回退默认值("设置改了不生效、重启回默认")；
    /// - 写值落到 `store ?? .standard` → 存得进去，但下次还是从 nil 里读；
    /// - 一次性迁移的 `guard let current = UserDefaults(suiteName:)` 直接失败 → 整个 no-op。
    ///
    /// v0.3.4 及更早（suite 名 = `com.local.appupdater` = 当时的 bundle id）一直带着这个
    /// bug，直到 v0.3.4 的迁移验证时才暴露。用 `bundleID + ".settings"` 结构性地错开，
    /// 顺带让「以后再改 bundle id，设置域跟着走」。
    public static let settingsSuiteName = "\(bundleID).settings"

    /// v0.3.3 及更早用的名字。**只用于兼容读取与一次性迁移**（见 `LegacyMigration`），
    /// 新代码一律用上面的常量。留着它的唯一理由：老用户机器上还挂着这些路径。
    public enum Legacy {
        public static let bundleID = "com.local.appupdater"
        public static let appFileName = "AppUpdater.app"
        public static let supportDirectoryName = "AppUpdater"
    }

    public static var releasesLatestURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    public static func isSelf(_ app: AppInfo) -> Bool {
        isSelf(bundleID: app.bundleID)
    }

    /// 新旧 Bundle ID 都算自己。
    ///
    /// 老版本（≤ v0.3.3）装在 `/Applications/AppUpdater.app`，Bundle ID 是
    /// `com.local.appupdater`。只认新 ID 的话，它会从「本机的其他应用」里冒出来，
    /// 被当成一个可以升级的第三方 App——那是最不该出现的一条。
    public static func isSelf(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == Self.bundleID || bundleID == Legacy.bundleID
    }

    /// 主列表是「本机的其他应用」。自己这条不混进去。
    public static func excludingSelf(_ apps: [AppInfo]) -> [AppInfo] {
        apps.filter { !isSelf($0) }
    }

    public static func excludingSelf(_ updates: [AppUpdate]) -> [AppUpdate] {
        updates.filter { !isSelf($0.app) }
    }

    /// 当前正在运行的 `.app` 包。从 `swift run` 或裸二进制启动时不是 `.app`，返回 nil。
    public static var runningAppURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    public static var currentShortVersion: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    public static var currentBuildVersion: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// 统一的 HTTP User-Agent 值。版本号从 Bundle 动态获取，
    /// CLI 或测试环境下回退到 "dev"。
    public static var userAgent: String {
        let version = currentShortVersion ?? "dev"
        return "\(displayName)/\(version) (macOS)"
    }

    /// 自替换的目标路径：优先正在运行的包，否则找 `/Applications` 下的自己。
    ///
    /// 新名字先找、旧名字兜底——老用户可能既不在跑、目录还叫 `AppUpdater.app`。
    public static func installTargetURL() -> URL? {
        if let running = runningAppURL { return running }
        for name in [appFileName, Legacy.appFileName] {
            let candidate = URL(fileURLWithPath: "/Applications/\(name)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// 自更新的目标目录：把可能残留的旧名字（`AppUpdater.app`）规范化成 `Updraft.app`，
    /// 让换包顺带完成改名，老用户点一次「升级」就行，不用手动折腾目录。
    ///
    /// 新名字已经被别的东西占着时退回原路径——宁可留个旧目录名，也不要覆盖别的东西。
    public static func canonicalTargetURL(for target: URL) -> URL {
        guard target.lastPathComponent != appFileName else { return target }
        let renamed = target.deletingLastPathComponent()
            .appendingPathComponent(appFileName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: renamed.path) else { return target }
        return renamed
    }

    public static func makeAppInfo(at url: URL, version: String? = nil) -> AppInfo {
        AppInfo(
            name: displayName,
            bundleID: bundleID,
            path: url,
            currentVersion: version ?? currentShortVersion ?? Installer.plistValue("CFBundleShortVersionString", in: url),
            buildVersion: currentBuildVersion ?? Installer.plistValue("CFBundleVersion", in: url),
            source: .unsupported(reason: "本工具自更新"),
            publicEDKey: publicEDKey
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
