import SwiftUI

/// 升级任务面板：确认 → 执行 → 结果，三态共用一个面板。
struct UpgradeSheet: View {
    @ObservedObject var store: UpdateStore

    var body: some View {
        Group {
            if let job = store.job {
                VStack(spacing: 0) {
                    header(job)
                    Divider()
                    content(job)
                    Divider()
                    footer(job)
                }
            }
        }
        .frame(width: 600, height: sheetHeight)
        .interactiveDismissDisabled(store.job?.isRunning == true)
    }

    /// 单个应用的确认面板内容较短，固定用 540 会留下大片空白。
    private var sheetHeight: CGFloat {
        guard let job = store.job else { return 540 }
        if !job.isRunning, !job.isFinished, job.items.count == 1, job.items.first?.plan != nil {
            return 470
        }
        return 540
    }

    // MARK: - 顶部

    private func header(_ job: UpgradeJob) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(Theme.Fonts.panelTitle)
                Text(subtitle(job))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            if job.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func subtitle(_ job: UpgradeJob) -> String {
        if job.isRunning {
            let progress = "正在处理第 \(job.currentIndex + 1) / \(job.items.count) 项"
            return job.cancelRequested ? progress + " · 已请求取消" : progress
        }
        if job.isFinished {
            var parts = ["成功 \(job.succeededCount) 项"]
            if job.failedCount > 0 { parts.append("失败 \(job.failedCount) 项") }
            if job.cancelledCount > 0 { parts.append("取消 \(job.cancelledCount) 项") }
            return parts.joined(separator: " · ")
        }
        if job.items.count == 1 {
            return "确认后开始，全程不修改其他应用"
        }
        return "\(job.automatedCount) 项可自动完成，将按顺序逐个执行"
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(_ job: UpgradeJob) -> some View {
        if job.isFinished {
            resultsView(job)
        } else if job.isRunning {
            runningView(job)
        } else if job.items.count == 1, let item = job.items.first, let plan = item.plan {
            singlePlanView(plan)
        } else {
            confirmListView(job)
        }
    }

    // MARK: 确认态 — 单个应用，展示完整预检结果

    private func singlePlanView(_ plan: Installer.Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("应用", plan.appName)
                    infoRow("标识", plan.bundleID)
                    versionRow(plan)
                    infoRow("安装包", packageDescription(plan))
                    if let host = plan.sourceHost {
                        infoRow("下载来源", host)
                    }
                    infoRow("签名校验", plan.signature.description)
                    infoRow("旧版备份", abbreviate(plan.backupLocation))
                    infoRow("当前状态", plan.isAppRunning ? "正在运行，升级前会先退出，装完自动重新打开" : "未在运行")
                }

                if !plan.warnings.isEmpty {
                    warningBox(plan.warnings)
                }

                Text("升级过程：下载 → 校验开发者签名 → 备份旧版本 → 退出应用 → 原子替换 → 验证新版本。任何一步失败都会自动回滚到 \(plan.fromVersion ?? "当前版本")。")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func versionRow(_ plan: Installer.Plan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            label("版本")
            HStack(spacing: 6) {
                Text(plan.fromVersion ?? "未知")
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(plan.toVersion)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .font(Theme.Fonts.caption)
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

    // MARK: 确认态 — 批量

    private func confirmListView(_ job: UpgradeJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                VStack(spacing: 0) {
                    ForEach(Array(job.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, Theme.Spacing.sm) }
                        HStack(spacing: 10) {
                            Image(systemName: item.action == .replaceBundle ? "arrow.down.circle" : "shippingbox")
                                .font(.system(size: 12))
                                .foregroundStyle(item.action == .replaceBundle ? Color.accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.app.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(item.app.currentVersion ?? "?") → \(item.release.version)")
                                    .font(Theme.Fonts.note)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Theme.Spacing.xs)
                            Text(item.action == .replaceBundle ? "校验+替换" : "Homebrew")
                                .font(Theme.Fonts.note)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 8)
                    }
                }
                .cardContainer()

                let unverified = job.items.filter { item in
                    if case .cannotVerify = item.plan?.signature { return true }
                    return false
                }
                if !unverified.isEmpty {
                    warningBox(unverified.map { "\($0.app.name)：\($0.plan?.signature.description ?? "")" })
                }

                Text("逐项串行执行，单项失败不会中断其余应用。每个应用升级前都会备份旧版本。")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: 执行态

    private func runningView(_ job: UpgradeJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if job.currentIndex < job.items.count {
                let item = job.items[job.currentIndex]
                HStack(spacing: 10) {
                    Text(item.app.name)
                        .font(Theme.Fonts.body)
                    Text("\(item.app.currentVersion ?? "?") → \(item.release.version)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, 10)

                if item.action == .replaceBundle {
                    phaseList(job.phase?.phase)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.bottom, Theme.Spacing.sm)
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(job.runningLog.isEmpty ? "准备中…" : job.runningLog)
                        .font(Theme.Fonts.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.md)
                        .id("log-tail")
                }
                .onChange(of: job.runningLog) { _ in
                    proxy.scrollTo("log-tail", anchor: .bottom)
                }
            }
            .background(Theme.Colors.textSurface)
        }
    }

    private func phaseList(_ current: Installer.Phase?) -> some View {
        let phases = Installer.Phase.allCases
        let currentIndex = current.flatMap { phases.firstIndex(of: $0) } ?? -1

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

    // MARK: 结果态

    private func resultsView(_ job: UpgradeJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(job.outcomes) { outcome in
                    outcomeCard(outcome)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func outcomeCard(_ outcome: UpgradeJob.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: symbol(for: outcome))
                    .font(.system(size: 13))
                    .foregroundStyle(tint(for: outcome))
                Text(outcome.appName)
                    .font(Theme.Fonts.body)
                Text("\(outcome.fromVersion ?? "?") → \(outcome.toVersion)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(outcome.summary)
                .font(Theme.Fonts.caption)
                .foregroundStyle(outcome.succeeded ? Color.secondary : tint(for: outcome))
                .fixedSize(horizontal: false, vertical: true)

            if outcome.rolledBack {
                Text("已回滚到升级前的版本，应用可以正常使用。")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
            }

            ForEach(outcome.warnings, id: \.self) { warning in
                Text("· \(warning)")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Spacing.md) {
                if let backup = outcome.backupPath {
                    Button("查看备份") { store.revealBackup(backup) }
                        .buttonStyle(.link)
                        .font(Theme.Fonts.note)
                }
                if !outcome.log.isEmpty {
                    DisclosureGroup("执行日志") {
                        Text(outcome.log)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Spacing.xxs)
                    }
                    .font(Theme.Fonts.note)
                }
                Spacer()
            }
        }
        .padding(Theme.Spacing.sm + 2)
        .cardContainer()
    }

    // MARK: - 底部

    /// 取消不该穿成失败的马甲：三种结果各给一套图标与颜色。
    private func symbol(for outcome: UpgradeJob.Outcome) -> String {
        if outcome.cancelled { return "minus.circle" }
        return outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func tint(for outcome: UpgradeJob.Outcome) -> Color {
        if outcome.cancelled { return .secondary }
        return outcome.succeeded ? Theme.Colors.success : Theme.Colors.attention
    }

    @ViewBuilder
    private func footer(_ job: UpgradeJob) -> some View {
        HStack(spacing: 10) {
            if job.isFinished {
                if job.failedCount > 0 {
                    Text("有 \(job.failedCount) 项未完成，可查看上方原因后重试")
                        .font(Theme.Fonts.note)
                        .foregroundStyle(.secondary)
                } else if job.cancelledCount > 0 {
                    Text("已取消 \(job.cancelledCount) 项，剩下的不会再动手")
                        .font(Theme.Fonts.note)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { store.dismissJob() }
                    .keyboardShortcut(.defaultAction)
            } else if job.isRunning {
                // 运行态必须留一个走得出去的口子。取消只在条目边界生效，
                // 所以文案要如实说明"当前这一项还会做完"，而不是假装立刻停。
                Text(job.cancelRequested
                     ? "已请求取消，当前应用完成后即停止…"
                     : (job.phase?.detail ?? "执行中…"))
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(job.cancelRequested ? "正在停止…" : "取消升级") {
                    store.cancelJob()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(job.cancelRequested)
            } else {
                Spacer()
                Button("取消") { store.dismissJob() }
                    .keyboardShortcut(.cancelAction)
                Button("开始升级") {
                    Task { await store.runJob() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
