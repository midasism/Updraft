import SwiftUI

public struct ContentView: View {
    @ObservedObject private var store: UpdateStore
    /// 打开设置窗口；nil 时不显示齿轮（截图通道走默认值，不需要真窗口路由）。
    private let openSettings: (() -> Void)?
    /// 筛选词。刻意留在视图态而不是 `UpdateStore`：它是瞬时的界面状态，
    /// 不该进状态源，也不该让 store 知道「搜索」这件事存在。
    @State private var query: String
    @FocusState private var isSearchFocused: Bool

    public init(store: UpdateStore, openSettings: (() -> Void)? = nil, initialQuery: String = "") {
        self.store = store
        self.openSettings = openSettings
        _query = State(initialValue: initialQuery)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = store.recoveryNotice {
                recoveryBanner(notice)
                Divider()
            }
            if case .updateAvailable(let release) = store.selfStatus {
                selfUpdateBanner(release)
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
        .sheet(isPresented: $store.isSelfUpdatePresented) {
            SelfUpdateSheet(store: store)
        }
    }

    // MARK: - 筛选

    /// 当前筛选结果。查询词为空时就是全量。
    private var filteredUpdates: [AppUpdate] {
        AppSearch.filter(store.updates, query: query)
    }

    private func filtered(in group: UpdateGroup) -> [AppUpdate] {
        filteredUpdates.filter { $0.group == group }
    }

    private var isFiltering: Bool { !AppSearch.tokenize(query).isEmpty }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 筛选后仍能自动完成的条目数，决定「升级这 N 个」是否出现。
    private var visibleAutomatedCount: Int {
        UpdateStore.automatedCandidates(in: filtered(in: .updateAvailable)).count
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Updraft")
                    .font(.system(size: 15, weight: .medium))
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            searchField

            if let notice = store.brewNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(notice)
            }

            if visibleAutomatedCount > 1, store.job?.isRunning != true {
                Button(isFiltering ? "升级这 \(visibleAutomatedCount) 个" : "全部升级") {
                    store.requestUpgradeAll(visible: filteredUpdates)
                }
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
            .disabled(store.isCheckBlocked)

            if let openSettings {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")
                .disabled(store.job?.isRunning == true)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
    }

    /// 增量刷新与全量扫描的代价差着一个数量级，文案上要让用户看得出来不是同一件事。
    private var checkButtonTitle: String {
        if store.isChecking { return "检查中…" }
        if store.isRefreshing { return "刷新中…" }
        return "重新检查"
    }

    /// 自绘搜索框。
    ///
    /// 不用 `.searchable`：它的落点依赖 NavigationStack / toolbar 容器，而这个窗口是
    /// 一段自排的 VStack，搜索框会被塞到哪一层不可预期；`--snapshot` 通道还要求
    /// 渲染确定、可复现。代价是 ⌘F 要自己接。
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("搜索应用", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("清除筛选")
                .accessibilityLabel("清除筛选")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSearchFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
        )
        .frame(width: 180)
        .onExitCommand { query = "" }
        .background(
            // 零尺寸的隐藏按钮只为接住 ⌘F。放在视图里而不是 .commands，是为了不把
            // 焦点状态（@FocusState）跨层传到 App 入口。
            Button("搜索") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .help("按名称或 Bundle ID 过滤（⌘F）")
    }

    private var subtitleText: String {
        if !store.statusMessage.isEmpty { return store.statusMessage }
        if store.updates.isEmpty { return "尚未检查" }
        if isFiltering {
            return "筛选“\(trimmedQuery)” · 命中 \(filteredUpdates.count) / 共 \(store.updates.count)"
        }
        let prefix = store.isShowingCachedResult ? "上次检查：\(store.lastCheckedText)" : store.lastCheckedText
        return "\(prefix) · 扫描 \(store.updates.count) 个应用"
    }

    // MARK: - 统计卡片

    private func selfUpdateBanner(_ release: SelfRelease) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("Updraft \(release.version) 已发布")
                .font(.system(size: 12, weight: .medium))
            Text("当前 \(SelfUpdateIdentity.currentShortVersion ?? "未知")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("查看") { store.presentSelfUpdate() }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    /// 上一次安装被中断留下的残留被清理/抢救过，如实告知。
    private func recoveryBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到上一次升级被中断")
                    .font(.system(size: 12, weight: .medium))
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("知道了") { store.dismissRecoveryNotice() }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "可更新", value: store.updateCount, tint: store.updateCount > 0 ? .orange : .secondary)
            StatCard(title: "已是最新", value: store.upToDateCount, tint: .green)
            StatCard(title: "无法自动检测", value: store.unsupportedCount, tint: .secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.updates.isEmpty {
            emptyState
        } else if isFiltering && filteredUpdates.isEmpty {
            noMatchState
        } else {
            List {
                ForEach(UpdateGroup.allCases) { group in
                    let items = filtered(in: group)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { update in
                                AppRowView(update: update, store: store)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(items.count)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
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
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(store.isBusy ? "正在检查…" : "还没有结果")
                .font(.system(size: 13, weight: .medium))
            Text("点右上角「重新检查」开始扫描已安装的应用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 筛选零命中。
    ///
    /// 必须与 `emptyState`（尚未检查）在文案上分得开：一个说「没搜到」，
    /// 一个说「还没查过」。混成一句的话，用户会以为应用真的没了。
    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("没有匹配“\(trimmedQuery)”的应用")
                .font(.system(size: 13, weight: .medium))
            Text("已扫描 \(store.updates.count) 个应用，换个词试试")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("清除筛选") { query = "" }
                .controlSize(.small)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 统计卡片：一个数字 + 一行说明。
struct StatCard: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
