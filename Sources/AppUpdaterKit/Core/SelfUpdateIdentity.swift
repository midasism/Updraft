import Foundation

/// Updraft 自己的身份：Bundle ID、GitHub 仓库、Ed25519 公钥。
///
/// 公钥与 CI secret `UPDRAFT_ED25519_PRIVATE_KEY` 是一对。
/// 私钥只存在 GitHub Actions secret 里，不进仓库。
public enum SelfUpdateIdentity {
    public static let bundleID = "com.local.appupdater"
    public static let appFileName = "AppUpdater.app"
    public static let displayName = "Updraft"
    public static let githubOwner = "midasism"
    public static let githubRepo = "Updraft"
    /// Ed25519 公钥（raw 32 字节，base64）。对应 CI secret `UPDRAFT_ED25519_PRIVATE_KEY`。
    public static let publicEDKey = "cEVR8yn/kKr4xV38t8A54sur94877mr01gi51IUfS10="

    public static var releasesLatestURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    public static func isSelf(_ app: AppInfo) -> Bool {
        isSelf(bundleID: app.bundleID)
    }

    public static func isSelf(bundleID: String?) -> Bool {
        bundleID == Self.bundleID
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

    /// 自替换的目标路径：优先正在运行的包，否则 `/Applications/AppUpdater.app`。
    public static func installTargetURL() -> URL? {
        if let running = runningAppURL { return running }
        let fallback = URL(fileURLWithPath: "/Applications/\(appFileName)")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return fallback
        }
        return nil
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
