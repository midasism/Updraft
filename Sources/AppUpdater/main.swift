import AppUpdaterKit
import Foundation

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func runAndWait(_ operation: @escaping () async -> Int32) -> Never {
    // 不能用信号量堵主线程：安装路径里有 MainActor 工作（AppKit / 拉起新实例），
    // 主线程一堵就会自锁。跑 RunLoop，让协作式调度能回到主线程。
    Task {
        let code = await operation()
        exit(code)
    }
    RunLoop.main.run()
    fatalError("unreachable")
}

// 无界面自检：跑一遍完整检测并打印结果。
if arguments.contains("--check") {
    runAndWait { await HeadlessCheck.run(); return 0 }
}

// 预检：只打印某个应用升级前的全部判断，不下载、不写入。
if let name = value(after: "--plan") {
    runAndWait { await InstallCommand.run(appName: name, dryRun: true) }
}

// 真实升级一个应用。
if let name = value(after: "--install") {
    runAndWait { await InstallCommand.run(appName: name, dryRun: false) }
}

// 升级全部可自动完成的条目。
if arguments.contains("--install-all") {
    runAndWait { await InstallCommand.runAll(dryRun: false) }
}

if arguments.contains("--plan-all") {
    runAndWait { await InstallCommand.runAll(dryRun: true) }
}

// 增量刷新：只重查指定的应用，不重新扫描应用目录。
if let name = value(after: "--refresh") {
    runAndWait { await RefreshCommand.run(appNames: [name]) }
}

if arguments.contains("--refresh-all") {
    runAndWait { await RefreshCommand.run(appNames: []) }
}

// 走界面状态源跑一次完整升级任务（含升级收尾的增量刷新）。会真实替换 App 包。
if let name = value(after: "--job") {
    let code = MainActor.assumeIsolated { JobCommand.run(appName: name) }
    exit(code)
}

// 清理上一次被中断的安装残留。
if arguments.contains("--recover") {
    exit(InstallCommand.recover())
}

// 本工具自更新：与 GUI 同源，不走主应用列表。
if arguments.contains("--self-check") {
    runAndWait { await SelfUpdateCommand.check() }
}

if arguments.contains("--self-install") {
    runAndWait { await SelfUpdateCommand.install() }
}

// 界面截图：把真实的视图渲染成 PNG，用于验证排版。
if let index = arguments.firstIndex(of: "--snapshot") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "app-snapshot.png"
    let mode = value(after: "--mode").flatMap(SnapshotRunner.Mode.init(rawValue:)) ?? .main
    let code = MainActor.assumeIsolated { SnapshotRunner.run(outputPath: path, mode: mode) }
    exit(code)
}

AppUpdaterApp.main()
