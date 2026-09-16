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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.system(size: 14, weight: .medium))
                Text(subtitle(job))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if job.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func versionRow(_ plan: Installer.Plan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label("版本")
            HStack(spacing: 6) {
                Text(plan.fromVersion ?? "未知")
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(plan.toVersion)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            }
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
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array(job.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 12) }
                        HStack(spacing: 10) {
                            Image(systemName: item.action == .replaceBundle ? "arrow.down.circle" : "shippingbox")
                                .font(.system(size: 12))
                                .foregroundStyle(item.action == .replaceBundle ? Color.accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.app.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(item.fromVersion) → \(item.release.version)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(item.action == .replaceBundle ? "校验+替换" : "Homebrew")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                let unverified = job.items.filter { item in
                    if case .cannotVerify = item.plan?.signature { return true }
                    return false
                }
                if !unverified.isEmpty {
                    warningBox(unverified.map { "\($0.app.name)：\($0.plan?.signature.description ?? "")" })
                }

                // 账本滞后：brew 报"过期"的依据是它自己的账本，而账本可能落后于磁盘
                // （应用被内建更新器升过就会这样）。此时点下去是把同一个版本重装一遍——
                // 有效（能顺带修正账本）但多余，代价得先说清楚，不能让它看起来像正常升级。
                let staleLedger = job.items.filter(\.hasStaleLedger)
                if !staleLedger.isEmpty {
                    warningBox(staleLedger.map { item in
                        "\(item.app.name)：Homebrew 记录的是 \(item.release.ledgerVersion ?? "未知")，"
                        + "磁盘上实际已是 \(item.app.currentVersion ?? "未知")（应用自己的更新器升过）。"
                        + "继续会重新安装 \(item.release.version) 并修正记录。"
                    })
                }

                Text("逐项串行执行，单项失败不会中断其余应用。每个应用升级前都会备份旧版本。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: 执行态

    private func runningView(_ job: UpgradeJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if job.currentIndex < job.items.count {
                let item = job.items[job.currentIndex]
                HStack(spacing: 10) {
                    Text(item.app.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(item.fromVersion) → \(item.release.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if item.action == .replaceBundle {
                    phaseList(job.phase?.phase)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(job.runningLog.isEmpty ? "准备中…" : job.runningLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("log-tail")
                }
                .onChange(of: job.runningLog) { _ in
                    proxy.scrollTo("log-tail", anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func phaseList(_ current: Installer.Phase?) -> some View {
        let phases = Installer.Phase.allCases
        let currentIndex = current.flatMap { phases.firstIndex(of: $0) } ?? -1

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(phases.enumerated()), id: \.element) { index, phase in
                HStack(spacing: 7) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
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
                        .font(.system(size: 11))
                        .foregroundStyle(index <= currentIndex ? Color.primary : Color.secondary)
                }
            }
        }
    }

    // MARK: 结果态

    private func resultsView(_ job: UpgradeJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(job.outcomes) { outcome in
                    outcomeCard(outcome)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func outcomeCard(_ outcome: UpgradeJob.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: outcome))
                    .font(.system(size: 13))
                    .foregroundStyle(tint(for: outcome))
                Text(outcome.appName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(outcome.fromVersion ?? "?") → \(outcome.toVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(outcome.summary)
                .font(.system(size: 12))
                .foregroundStyle(outcome.succeeded ? Color.secondary : tint(for: outcome))
                .fixedSize(horizontal: false, vertical: true)

            if outcome.rolledBack {
                Text("已回滚到升级前的版本，应用可以正常使用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(outcome.warnings, id: \.self) { warning in
                Text("· \(warning)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                if let backup = outcome.backupPath {
                    Button("查看备份") { store.revealBackup(backup) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                if !outcome.log.isEmpty {
                    DisclosureGroup("执行日志") {
                        Text(outcome.log)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.system(size: 11))
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 底部

    /// 取消不该穿成失败的马甲：三种结果各给一套图标与颜色。
    private func symbol(for outcome: UpgradeJob.Outcome) -> String {
        if outcome.cancelled { return "minus.circle" }
        return outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func tint(for outcome: UpgradeJob.Outcome) -> Color {
        if outcome.cancelled { return .secondary }
        return outcome.succeeded ? .green : .orange
    }

    @ViewBuilder
    private func footer(_ job: UpgradeJob) -> some View {
        HStack(spacing: 10) {
            if job.isFinished {
                if job.failedCount > 0 {
                    Text("有 \(job.failedCount) 项未完成，可查看上方原因后重试")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if job.cancelledCount > 0 {
                    Text("已取消 \(job.cancelledCount) 项，剩下的不会再动手")
                        .font(.system(size: 11))
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
                    .font(.system(size: 11))
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 小组件

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 68, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(title)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func warningBox(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
