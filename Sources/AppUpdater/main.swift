import AppUpdaterKit
import Foundation

let arguments = CommandLine.arguments

// 无界面自检：跑一遍完整检测并打印结果。
if arguments.contains("--check") {
    // main.swift 的顶层代码不能直接 await，用信号量把结果等出来再退出。
    let done = DispatchSemaphore(value: 0)
    Task {
        await HeadlessCheck.run()
        done.signal()
    }
    done.wait()
    exit(0)
}

// 界面截图：把真实的 ContentView 渲染成 PNG，用于验证排版。
if let index = arguments.firstIndex(of: "--snapshot") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "app-snapshot.png"
    let code = MainActor.assumeIsolated { SnapshotRunner.run(outputPath: path) }
    exit(code)
}

AppUpdaterApp.main()
