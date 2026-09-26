import SwiftUI

public struct ContentView: View {
    @ObservedObject private var store: UpdateStore

    public init(store: UpdateStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = store.recoveryNotice {
                recoveryBanner(notice)
                Divider()
            }
            if let status = store.selfUpdateStatus {
                selfUpdateOutcomeBanner(status)
                Divider()
            } else if case .available(let release) = store.selfUpdate {
                selfUpdateAvailableBanner(release)
                Divider()
            }
            statsRow
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $store.job) { _ in
            UpgradeSheet(store: store)
        }
        .sheet(item: $store.selfSheet) { _ in
            SelfUpdateSheet(store: store)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("App 更新")
                    .font(Theme.Fonts.title)
                Text(subtitleText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if !store.brewAvailable {
                Label("未找到 Homebrew", systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if store.automatedUpdateCount > 1, store.job?.isRunning != true {
                Button("全部升级") {
                    store.requestUpgradeAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
            }

            Button {
                Task { await store.check() }
            } label: {
                HStack(spacing: 6) {
                    if store.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text(checkButtonTitle)
                }
                .frame(minWidth: 68)
            }
            .buttonStyle(.bordered)
            .disabled(store.isBusy || store.job?.isRunning == true)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// 增量刷新与全量扫描的代价差着一个数量级，文案上要让用户看得出来不是同一件事。
    private var checkButtonTitle: String {
        if store.isChecking { return "检查中…" }
        if store.isRefreshing { return "刷新中…" }
        return "重新检查"
    }

    private var subtitleText: String {
        if !store.statusMessage.isEmpty { return store.statusMessage }
        if store.updates.isEmpty { return "尚未检查" }
        let prefix = store.isShowingCachedResult ? "上次检查：\(store.lastCheckedText)" : store.lastCheckedText
        return "\(prefix) · 扫描 \(store.updates.map(\.app.name).count) 个应用"
    }

    // MARK: - 统计卡片

    /// 上一次安装被中断留下的残留被清理/抢救过，如实告知。
    private func recoveryBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.attention)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("检测到上一次升级被中断")
                    .font(.system(size: 12, weight: .semibold))
                Text(notice)
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Button("知道了") { store.dismissRecoveryNotice() }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.attentionWash)
    }

    // MARK: - 本应用自身的更新

    /// 本应用有新版本。单开一条横幅而不是塞进列表：它的更新方式与列表里那些不同源，
    /// 目标就是正在运行的自己——要先退出才能换包。
    private func selfUpdateAvailableBanner(_ release: SelfUpdateRelease) -> some View {
        let current = SelfIdentity.currentVersion ?? "?"
        var detail = "AppUpdater \(current) → \(release.version)"
        if let size = release.size, size > 0 {
            detail += " · \(AppUpdate.formatBytes(size))"
        }
        detail += " · 可在应用内直接更新"

        return banner(
            icon: "arrow.down.circle.fill",
            tint: Color.accentColor,
            wash: Color.accentColor.opacity(0.08),
            title: "AppUpdater 有新版本",
            message: detail,
            actions: AnyView(
                HStack(spacing: Theme.Spacing.xs) {
                    Button("发布说明") { store.openReleasePage() }
                        .controlSize(.small)
                    Button("更新") { store.requestSelfUpdate() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            )
        )
    }

    /// 上一次自更新的交接结果。成功与失败都要说，因为换包发生在应用退出之后——
    /// 用户没有别的渠道知道到底成了没有。
    private func selfUpdateOutcomeBanner(_ status: SelfUpdateStatus) -> some View {
        let succeeded = status.outcome == .succeeded
        var message = status.message
        if let backup = status.backupPath {
            message += " · 旧版本备份在 \(backup.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))"
        }

        return banner(
            icon: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: succeeded ? Theme.Colors.success : Theme.Colors.attention,
            wash: succeeded ? Theme.Colors.success.opacity(0.08) : Theme.Colors.attentionWash,
            title: succeeded ? "AppUpdater 已更新" : "上一次自更新没有完成",
            message: message,
            actions: AnyView(
                HStack(spacing: Theme.Spacing.xs) {
                    if !succeeded {
                        Button("打开发布页面") { store.openReleasePage() }
                            .controlSize(.small)
                    }
                    Button("知道了") { store.dismissSelfUpdateStatus() }
                        .controlSize(.small)
                }
            )
        )
    }

    /// 横幅的公共骨架：图标 + 标题 + 说明 + 右侧动作。
    private func banner(
        icon: String,
        tint: Color,
        wash: Color,
        title: String,
        message: String,
        actions: AnyView
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.xs)
            actions
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(wash)
    }

    private var statsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatCard(title: "可更新", value: store.updateCount, tint: store.updateCount > 0 ? Theme.Colors.attention : Color.secondary)
            StatCard(title: "已忽略", value: store.ignoredCount, tint: .secondary)
            StatCard(title: "已是最新", value: store.upToDateCount, tint: Theme.Colors.success)
            StatCard(title: "无法自动检测", value: store.unsupportedCount, tint: .secondary)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.updates.isEmpty {
            emptyState
        } else {
            List {
                ForEach(UpdateGroup.displayOrder) { group in
                    let items = store.updates(in: group)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { update in
                                AppRowView(update: update, store: store)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(items.count)")
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.isBusy ? "正在检查…" : "还没有结果")
                .font(.system(size: 13, weight: .semibold))
            Text("点右上角「重新检查」开始扫描已安装的应用")
                .font(Theme.Fonts.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 统计卡片：一个数字 + 一行说明，细描边容器撑起质感。
struct StatCard: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(Theme.Fonts.statValue)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
        .cardContainer()
    }
}
