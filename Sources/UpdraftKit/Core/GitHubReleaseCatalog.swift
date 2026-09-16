import Foundation

/// GitHub Release 白名单：`bundleID → owner/repo`。
///
/// 没有任何可靠途径从包内自动推出 owner/repo——`io.github.*` 这种反向域名只对
/// 部分项目成立，猜错就是查到别人的仓库上去。所以这张表**手工维护**，
/// 每一条都经过 `api.github.com/repos/<owner>/<repo>/releases/latest` 实测（2026-09-16）。
///
/// 表里没有的应用行为完全不变（仍按原分类走，多数是 `unsupported`）。
/// 加新条目时顺手在 `Tests/UpdraftTests/GitHubReleaseTests.swift` 的
/// `testCatalogEntriesAreWellFormed` 里补一行断言，格式错了 CI 会拦。
public enum GitHubReleaseCatalog: Sendable {
    private static let repos: [String: String] = [
        // AltTab：内嵌 Sparkle 但 feed 硬编码，GitHub 才是它真正的发布渠道。
        "com.lwouis.alt-tab-macos": "lwouis/alt-tab-macos",
        // Clash Verge Rev。
        "io.github.clash-verge-rev.clash-verge-rev": "clash-verge-rev/clash-verge-rev",
        // DBeaver Community。
        "org.jkiss.dbeaver.core.product": "dbeaver/dbeaver",
        // FlClash。
        "com.follow.clash": "chen08209/FlClash",
        // Insomnia。tag 形如 `core@13.2.0`，归一逻辑见 `GitHubReleaseProbe.version(fromTag:)`。
        "com.insomnia.app": "Kong/insomnia",
        // Zed。
        "dev.zed.Zed": "zed-industries/zed",
    ]

    /// 命中白名单返回 `owner/repo`，未命中返回 `nil`。
    public static func repo(forBundleID bundleID: String) -> String? {
        repos[bundleID]
    }

    /// 该 bundleID 是否在白名单内。分类器用它决定要不要走 GitHub 通道。
    public static func contains(bundleID: String) -> Bool {
        repos[bundleID] != nil
    }

    /// `/releases/latest` 端点。它自动排除 draft 与 prerelease，不需要自己过滤。
    static func latestReleaseURL(bundleID: String) -> URL? {
        guard let repo = repos[bundleID], !repo.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }
}
