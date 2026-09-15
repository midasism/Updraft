import SwiftUI

/// 本工具自更新面板。与主列表的升级确认分开：换自己要退出当前进程。
struct SelfUpdateSheet: View {
    @ObservedObject var store: UpdateStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .interactiveDismissDisabled(store.isInstallingSelf)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("升级 Updraft")
                    .font(.system(size: 14, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if store.isCheckingSelf || store.isInstallingSelf {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if store.isInstallingSelf {
            return store.selfInstallProgress.map { "\($0.phase.title) — \($0.detail)" } ?? "正在升级…"
        }
        if let report = store.selfInstallReport {
            return report.succeeded ? "已升级，即将打开新版本" : "升级未完成"
        }
        if store.isCheckingSelf { return "正在检查…" }
        switch store.selfStatus {
        case .updateAvailable(let release):
            return "\(SelfUpdateIdentity.currentShortVersion ?? "当前版本") → \(release.version)"
        case .upToDate(let latest):
            return "已是最新 \(latest)"
        case .failed(let reason):
            return "检查失败 · \(reason)"
        case nil:
            return "尚未检查"
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isInstallingSelf {
            runningView
        } else if let report = store.selfInstallReport {
            resultView(report)
        } else if store.isCheckingSelf {
            checkingView
        } else if case .updateAvailable(let release) = store.selfStatus, let plan = store.selfUpdatePlan() {
            confirmView(release: release, plan: plan)
        } else {
            statusView
        }
    }

    private var checkingView: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text("正在查询 GitHub Releases…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch store.selfStatus {
            case .upToDate(let latest):
                Label("已是最新 \(latest)", systemImage: "checkmark.circle")
                    .font(.system(size: 13))
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .updateAvailable:
                EmptyView()
            case nil:
                Text("还没有检查结果")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmView(release: SelfRelease, plan: Installer.Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    row("当前版本", plan.fromVersion ?? "未知")
                    row("新版本", plan.toVersion)
                    row("安装包", packageDescription(plan))
                    if let host = plan.sourceHost {
                        row("下载来源", host)
                    }
                    row("签名校验", release.canVerifySignature
                        ? "清单 Ed25519 + zip SHA-256 + 代码签名"
                        : "未提供签名清单，将标「未校验」")
                    row("旧版备份", abbreviate(plan.backupLocation))
                }

                if !plan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("确认后会下载并替换 /Applications 里的本工具，随后自动打开新版本。当前窗口会退出。失败则回滚到 \(plan.fromVersion ?? "当前版本")。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = store.selfInstallProgress {
                Text(progress.phase.title)
                    .font(.system(size: 13, weight: .medium))
                Text(progress.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            } else {
                ProgressView()
                Text("正在准备…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultView(_ report: Installer.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.succeeded {
                Label("已升级到 \(report.toVersion)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
                Text(report.signature.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("即将打开新版本并退出当前窗口。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Label(report.error ?? "升级失败", systemImage: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if report.rolledBack {
                    Text("已回滚到升级前的版本。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if store.isInstallingSelf {
                Text("正在替换本工具，请勿退出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if store.selfInstallReport?.succeeded == true {
                Button("关闭") { store.dismissSelfUpdate() }
                    .keyboardShortcut(.cancelAction)
            } else if case .updateAvailable = store.selfStatus, store.selfInstallReport == nil {
                Button("取消") { store.dismissSelfUpdate() }
                    .keyboardShortcut(.cancelAction)
                Button("升级并重启") {
                    Task { await store.installSelfUpdate() }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("重新检查") {
                    Task { await store.checkSelfUpdate() }
                }
                Button("关闭") { store.dismissSelfUpdate() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func packageDescription(_ plan: Installer.Plan) -> String {
        var parts = [plan.packageKind.displayName]
        if let size = plan.downloadSize, size > 0 {
            parts.insert(AppUpdate.formatBytes(size), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    private func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
