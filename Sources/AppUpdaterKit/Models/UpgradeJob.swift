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
    public var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
}
