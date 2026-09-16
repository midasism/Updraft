import Foundation

/// 判定每个应用走哪条更新通道。
///
/// 判定顺序不能随意调换：`mac-mouse-fix` 既是 Homebrew cask 又内嵌了 Sparkle，
/// 必须让 Homebrew 优先——只有它能在本工具里一键升完。
public struct AppClassifier: Sendable {
    private let caskIndex: BrewCaskIndex?

    public init(caskIndex: BrewCaskIndex?) {
        self.caskIndex = caskIndex
    }

    /// - Parameter trustedFallback: brew 索引拿不到时的兜底来源。
    ///
    ///   增量刷新只重读了变更过的那一个包，没有索引就无法重新判断它是不是 Homebrew cask。
    ///   此时沿用上一次全量扫描给出的来源，比凭空把它降级成"未知来源"准确得多——
    ///   对一个刚刚被本工具升过级的应用来说，"它归谁管"这件事根本没变。
    public func classify(_ scanned: ScannedApp, trustedFallback: AppSource? = nil) -> AppInfo {
        AppInfo(
            name: scanned.name,
            bundleID: scanned.bundleID,
            path: scanned.path,
            currentVersion: scanned.currentVersion,
            buildVersion: scanned.buildVersion,
            source: source(for: scanned, trustedFallback: trustedFallback),
            publicEDKey: scanned.publicEDKey
        )
    }

    private func source(for scanned: ScannedApp, trustedFallback: AppSource?) -> AppSource {
        // 0. 没有索引就没有判断依据，只能沿用上一次的结论。
        //    有索引时下面的判定是完整的，不需要兜底。
        if caskIndex == nil, let trustedFallback {
            return trustedFallback
        }

        // 1. Homebrew cask —— 唯一能全自动升级的一类，优先级最高。
        if let token = caskIndex?.token(forAppFileName: scanned.path.lastPathComponent) {
            return .homebrewCask(token: token)
        }

        // 2. App Store 收据。
        if scanned.hasMASReceipt {
            return .appStore
        }

        // 3. Sparkle。有 feed 地址才能查，没有的只能标为不支持。
        if let feedURLString = scanned.feedURLString,
           let url = URL(string: feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .sparkle(feedURL: url)
        }
        if scanned.hasEmbeddedSparkle {
            return .unsupported(reason: "内嵌 Sparkle 但更新源在程序内硬编码")
        }

        // 4. Electron 自带更新器。
        if scanned.appUpdateYML != nil {
            return .electron(feedURL: nil)
        }

        // 5. 微软自家更新器。
        if let bundleID = scanned.bundleID, bundleID.hasPrefix("com.microsoft.") {
            return .microsoftAutoUpdate
        }
        if scanned.name.hasPrefix("Microsoft ") || scanned.name == "Microsoft Edge" {
            return .microsoftAutoUpdate
        }

        // 6. 明确知道是专有更新器，理由写清楚比笼统的"未知"有用得多。
        if let reason = Self.proprietaryReason(for: scanned) {
            return .unsupported(reason: reason)
        }

        return .unsupported(reason: "未识别到公开的更新接口")
    }

    private static let proprietaryPatterns: [(needle: String, reason: String)] = [
        ("adobe", "Adobe 自家更新器"),
        ("creative cloud", "Adobe Creative Cloud 管理"),
        ("battle.net", "Battle.net 客户端内更新"),
        ("blizzard", "Battle.net 客户端内更新"),
        ("steam", "Steam 客户端内更新"),
        ("epic games", "Epic 客户端内更新"),
        ("jetbrains", "JetBrains Toolbox 管理"),
        ("vmware", "VMware 自家更新"),
        ("logioptions", "Logi Options+ 自更新"),
        ("logitech", "Logi Options+ 自更新"),
        ("google chrome", "Google 私有更新接口"),
        ("hearthstone", "Battle.net 客户端内更新"),
        ("blackmagic", "Blackmagic 官网手动更新"),
        ("final cut", "随 macOS 系统更新"),
        ("davinci resolve", "Blackmagic 官网手动更新")
    ]

    private static func proprietaryReason(for scanned: ScannedApp) -> String? {
        let haystacks = [scanned.name.lowercased(), (scanned.bundleID ?? "").lowercased()]
        for pattern in proprietaryPatterns {
            for haystack in haystacks where haystack.contains(pattern.needle) {
                return pattern.reason
            }
        }
        return nil
    }
}
