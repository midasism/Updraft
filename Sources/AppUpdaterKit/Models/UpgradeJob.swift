import Foundation

/// 一次升级任务。
///
/// 单个应用升级就是只有一个条目的任务，批量升级是多条目任务——两者共用同一套
/// 状态机与界面，省掉两条几乎相同却各自出 bug 的代码路径。
public struct UpgradeJob: Identifiable, Sendable {
    public enum ItemState: Equatable, Sendable {
        case pending
        case running
        case succeeded
        case failed(String)
        case skipped(String)

        public var isTerminal: Bool {
            switch self {
            case .pending, .running: return false
            case .succeeded, .failed, .skipped: return true
            }
        }
    }

    public struct Item: Identifiable, Sendable {
        public let app: AppInfo
        public let release: ReleaseInfo
        public let action: InstallAction
        /// 自动替换类才有预检计划；Homebrew 与只跳转的没有。
        public let plan: Installer.Plan?
        public var state: ItemState = .pending

        public var id: String { app.id }
        public var isAutomated: Bool { action.isAutomated }
    }

    /// 一个条目的执行结果，Homebrew 与自动安装共用。
    public struct Outcome: Identifiable, Sendable {
        public let id: String
        public let appName: String
        public let fromVersion: String?
        public let toVersion: String
        public let succeeded: Bool
        /// 一行摘要：成功说升到了哪个版本，失败说为什么。
        public let summary: String
        public let backupPath: URL?
        public let rolledBack: Bool
        public let warnings: [String]
        public let log: String
        /// 因为用户取消而没有执行。与"失败"分开记：界面上不该把它标成橙色警告。
        public var cancelled: Bool = false
    }

    public let id: UUID
    public var items: [Item]
    public var currentIndex: Int = 0
    /// 当前正在进行的阶段（仅自动安装类有）。
    public var phase: Installer.Progress?
    public var runningLog: String = ""
    public var outcomes: [Outcome] = []
    public var isRunning: Bool = false
    public var isFinished: Bool = false
    /// 已请求取消。语义是「当前这一项照常做完，之后不再往下走」——
    /// 中途打断原子换包才是真的危险，所以取消只在条目边界生效。
    public var cancelRequested: Bool = false

    public init(items: [Item]) {
        self.id = UUID()
        self.items = items
    }

    public var automatedCount: Int { items.filter(\.isAutomated).count }

    /// 只跳转、不代劳的条目，确认界面上要单独说明。
    public var manualItems: [Item] { items.filter { !$0.isAutomated } }

    public var title: String {
        if items.count == 1, let first = items.first {
            return "升级 \(first.app.name)"
        }
        return "批量升级 \(items.count) 个应用"
    }

    public var succeededCount: Int { outcomes.filter(\.succeeded).count }
    /// 只算真正的失败：用户主动取消的那些不该被算成"未完成需重试"。
    public var failedCount: Int { outcomes.filter { !$0.succeeded && !$0.cancelled }.count }
    public var cancelledCount: Int { outcomes.filter(\.cancelled).count }

    /// 收尾取消：把 `index` 起的未完成条目如实标成「已取消」，并为每条补一份结果，
    /// 这样结果页能看见"哪些没做"，而不是静默消失。
    ///
    /// 抽成纯函数是为了能直接断言"取消后剩余条目变成什么状态"，不必真跑一次升级。
    public mutating func cancelRemaining(from index: Int) -> [Outcome] {
        guard index < items.count else { return [] }
        var produced: [Outcome] = []
        for position in index..<items.count where !items[position].state.isTerminal {
            items[position].state = .skipped("已取消")
            produced.append(Outcome(
                id: items[position].id,
                appName: items[position].app.name,
                fromVersion: items[position].app.currentVersion,
                toVersion: items[position].release.version,
                succeeded: false,
                summary: "已取消，未执行",
                backupPath: nil,
                rolledBack: false,
                warnings: [],
                log: "",
                cancelled: true
            ))
        }
        return produced
    }
}
