import OSLog

/// 统一日志入口。所有模块通过此处获取 Logger，使日志自动接入 Console.app。
///
/// 用法：
/// ```swift
/// Log.probe.info("检查 \(app.name) 的更新")
/// Log.install.error("签名校验失败：\(error)")
/// ```
///
/// 在终端用 `log stream --predicate 'subsystem == "com.midasism.updraft"'` 实时查看，
/// 或在 Console.app 中按 subsystem 筛选。
enum Log {
    private static let subsystem = "com.midasism.updraft"

    /// 更新探测（Sparkle / Electron / GitHub / MAS / Brew 信息查询）
    static let probe      = Logger(subsystem: subsystem, category: "probe")
    /// 安装流程（下载、解压、签名校验、备份、换包、回滚）
    static let install    = Logger(subsystem: subsystem, category: "install")
    /// Homebrew 交互（索引构建、cask 升级）
    static let brew       = Logger(subsystem: subsystem, category: "brew")
    /// HTTP 网络请求
    static let net        = Logger(subsystem: subsystem, category: "net")
    /// 应用扫描与分类
    static let scan       = Logger(subsystem: subsystem, category: "scan")
    /// 子进程管理
    static let process    = Logger(subsystem: subsystem, category: "process")
    /// 自更新
    static let selfUpdate = Logger(subsystem: subsystem, category: "self-update")
    /// UI 状态管理
    static let store      = Logger(subsystem: subsystem, category: "store")
}
