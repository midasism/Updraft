import AppKit
import SwiftUI

/// 自身更新的面板：确认 → 执行 → 交接 → 失败，四态共用一个面板。
struct SelfUpdateSheet: View {
    @ObservedObject var store: UpdateStore

    var body: some View {
        Group {
            if let state = store.selfSheet {
                VStack(spacing: 0) {
                    header(state)
                    Divider()
                    content(state)
                    Divider()
                    footer(state)
                }
            }
        }
        .frame(width: 580, height: height)
        .interactiveDismissDisabled(store.isSelfUpdating)
    }

    /// 交接态要留出空间把"助手已经在跑、现在不能取消"讲清楚。
    private var height: CGFloat {
        switch store.selfSheet {
        case .handedOff, .failed, .upToDate: return 380
        default: return 480
        }
    }

    // MARK: - 顶部

    private func header(_ state: SelfUpdateSheetState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(state))
                    .font(Theme.Fonts.panelTitle)
                Text(subtitle(state))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            if store.isSelfUpdating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func title(_ state: SelfUpdateSheetState) -> String {
        switch state {
        case .confirming(let plan): return "更新 AppUpdater 到 \(plan.release.version)"
        case .running: return "正在更新 AppUpdater"
        case .handedOff: return "更新已就绪"
        case .upToDate: return "AppUpdater 已是最新"
        case .failed: return "无法在应用内完成更新"
        }
    }

    private func subtitle(_ state: SelfUpdateSheetState) -> String {
        switch state {
        case .confirming:
            return "下载完成后应用会自动退出并重新打开，中途不需要你做别的"
        case .running(let phase, _, _):
            return phase.title
        case .handedOff(_, let to):
            return "\(to) 已校验并预置好，应用马上退出并重新打开"
        case .upToDate(_, let latest):
            return "当前版本 \(latest)"
        case .failed:
            return "可以改从发布页面手动下载安装"
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(_ state: SelfUpdateSheetState) -> some View {
        switch state {
        case .confirming(let plan): planView(plan)
        case .running(let phase, let detail, let fraction): runningView(phase: phase, detail: detail, fraction: fraction)
        case .handedOff(let from, let to): handedOffView(from: from, to: to)
        case .upToDate: upToDateView()
        case .failed(let reason): failedView(reason)
        }
    }

    private func upToDateView() -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.success)
                Text("没有可用的新版本")
                    .font(Theme.Fonts.body)
            }

            Text("本应用会读取自己仓库的 Release 来比对版本。有新版本时，窗口顶部会出现一条横幅，点一下就能在应用内升级——不需要重新下载安装包。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("检查结果会缓存 3 小时以避免频繁请求接口；从菜单再点一次「检查更新…」总是会重新查。")
                .font(Theme.Fonts.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planView(_ plan: SelfUpdater.Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("应用", "AppUpdater（本应用）")
                    versionRow(plan)
                    infoRow("安装包", packageDescription(plan))
                    infoRow("下载来源", plan.release.sourceHost ?? "GitHub")
                    infoRow("完整性校验", plan.checksumSource)
                    infoRow("签名校验", plan.signature)
                    infoRow("旧版备份", abbreviate(plan.backupLocation))
                    infoRow("安装位置", plan.target.path)
                }

                if !plan.warnings.isEmpty {
                    warningBox(plan.warnings)
                }

                Text("更新过程：下载 → 校验完整性 → 校验签名 → 备份当前版本 → 预置新版本 → 应用退出 → 原子替换 → 自动重新打开。任何一步失败都会中止，磁盘上的应用保持原样。")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func versionRow(_ plan: SelfUpdater.Plan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            label("版本")
            HStack(spacing: 6) {
                Text(plan.currentVersion)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(plan.release.version)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .font(Theme.Fonts.caption)
            Spacer()
        }
    }

    private func packageDescription(_ plan: SelfUpdater.Plan) -> String {
        var parts = [plan.release.packageKind.displayName]
        if let size = plan.release.size, size > 0 {
            parts.insert(AppUpdate.formatBytes(size), at: 0)
        }
        parts.append(plan.release.assetName)
        return parts.joined(separator: " · ")
    }

    private func runningView(phase: SelfUpdater.Phase, detail: String, fraction: Double?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }

                phaseList(phase)

                Text(detail)
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("应用会在最后一步自动退出并重新打开，请不要手动关闭它。")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseList(_ current: SelfUpdater.Phase) -> some View {
        let phases = SelfUpdater.Phase.allCases
        let currentIndex = phases.firstIndex(of: current) ?? -1

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(phases.enumerated()), id: \.element) { index, phase in
                HStack(spacing: 7) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Colors.success)
                        } else if index == currentIndex {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .font(.system(size: 11))
                    .frame(width: 14)

                    Text(phase.title)
                        .font(Theme.Fonts.note)
                        .foregroundStyle(index <= currentIndex ? Color.primary : Color.secondary)
                }
            }
        }
    }

    private func handedOffView(from: String?, to: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.success)
                Text("\(from ?? "当前版本") → \(to)")
                    .font(Theme.Fonts.body)
            }

            Text("新版本已经下载、校验并预置到安装位置旁边，更新助手已经在等待。接下来应用会退出，助手完成最后两次改名并自动打开新版本。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("这一步已经没有可取消的了——助手的替换是原子的，中断反而会留下不完整的包。整个过程通常一两秒。")
                .font(Theme.Fonts.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failedView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.attention)
                    .padding(.top, 2)
                Text(reason)
                    .font(Theme.Fonts.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("磁盘上的应用没有被改动。可以重试，或者去发布页面手动下载安装包。")
                .font(Theme.Fonts.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部

    @ViewBuilder
    private func footer(_ state: SelfUpdateSheetState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .confirming(let plan):
                Button("查看发布说明") {
                    if let url = plan.release.releaseNotesURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .font(Theme.Fonts.note)
                Spacer()
                Button("稍后") { store.dismissSelfSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("立即更新") {
                    Task { await store.runSelfUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .running:
                Text("执行中，不要退出应用…")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                Spacer()

            case .handedOff:
                Text("应用即将退出…")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                Spacer()

            case .upToDate:
                Button("打开发布页面") { store.openReleasePage() }
                Spacer()
                Button("关闭") { store.dismissSelfSheet() }
                    .keyboardShortcut(.cancelAction)

            case .failed:
                Button("打开发布页面") { store.openReleasePage() }
                Spacer()
                Button("关闭") { store.dismissSelfSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm + 2)
    }

    // MARK: - 小组件

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            label(title)
            Text(value)
                .font(Theme.Fonts.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func warningBox(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.attention)
                        .padding(.top, 2)
                    Text(warning)
                        .font(Theme.Fonts.note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.attentionWash)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small + 2, style: .continuous))
    }

    private func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
