import Foundation

/// 本工具自更新的命令行入口，与 GUI 同源。
///
///     AppUpdater --self-check      只查，不下载
///     AppUpdater --self-install    查完后下载、验签、替换自己
public enum SelfUpdateCommand {
    public static func check() async -> Int32 {
        let status = await SelfUpdateChecker().check()
        printStatus(status, current: SelfUpdateIdentity.currentShortVersion)
        switch status {
        case .updateAvailable: return 0
        case .upToDate: return 0
        case .failed: return 1
        }
    }

    public static func install() async -> Int32 {
        let current = SelfUpdateIdentity.currentShortVersion
        print("→ 检查 Updraft 自身更新…")
        let status = await SelfUpdateChecker().check(currentVersion: current)
        printStatus(status, current: current)

        guard case .updateAvailable(let release) = status else {
            return status.isFailure ? 1 : 0
        }

        guard let target = SelfUpdateIdentity.installTargetURL() else {
            print("✘ 找不到可替换的 AppUpdater.app（需要装在 /Applications 或 ~/Applications）")
            return 1
        }
        guard AppUpdate.isReplaceable(target) else {
            print("✘ \(target.path) 不在可自动替换的位置，拒绝改写")
            return 1
        }

        let app = SelfUpdateIdentity.makeAppInfo(at: target, version: current)
        let installer = Installer()
        let plan = installer.makePlan(app: app, release: release.releaseInfo)
        print("")
        print("将替换正在运行的本工具，完成后会自动打开新版本。")
        InstallCommand.printPlan(plan)
        if release.canVerifySignature {
            print("  清单      将校验 Ed25519 签名与 zip SHA-256")
        } else {
            print("  清单      未提供签名清单，安装后标「未校验」")
        }

        print("")
        let report = await installer.install(
            app: app,
            release: release.releaseInfo,
            options: .selfUpdate(
                manifestBytes: release.manifestBytes,
                manifestSignature: release.manifestSignature,
                publicKey: SelfUpdateIdentity.publicEDKey
            )
        ) { progress in
            FileHandle.standardOutput.write(Data("  [\(progress.phase.title)] \(progress.detail)\n".utf8))
        }
        InstallCommand.printReport(report)
        guard report.succeeded else { return 1 }

        print("→ 新版本已就位，当前进程即将退出")
        return 0
    }

    private static func printStatus(_ status: SelfUpdateStatus, current: String?) {
        let local = current ?? "未知"
        switch status {
        case .updateAvailable(let release):
            let size = release.size.map { " · \(AppUpdate.formatBytes($0))" } ?? ""
            print("→ 有新版本：\(local) → \(release.version)\(size)")
            print("  下载 \(release.downloadURL.absoluteString)")
            if release.canVerifySignature {
                print("  签名清单已就绪")
            } else {
                print("  ⚠︎ 未提供签名清单，安装时将标「未校验」")
            }
        case .upToDate(let latest):
            print("→ 已是最新 \(latest)")
        case .failed(let reason):
            print("✘ 检查失败：\(reason)")
        }
    }
}

extension SelfUpdateStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
