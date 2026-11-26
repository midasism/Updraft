import AppKit
import SwiftUI

public struct ContentView: View {
    @ObservedObject private var store: UpdateStore
    /// 打开设置窗口；nil 时不显示齿轮（截图通道走默认值，不需要真窗口路由）。
    private let openSettings: (() -> Void)?
    /// 筛选词。刻意留在视图态而不是 `UpdateStore`：它是瞬时的界面状态，
    /// 不该进状态源，也不该让 store 知道「搜索」这件事存在。
    @State private var query: String
    @State private var selection: SidebarNav = .updateAvailable
    @FocusState private var isSearchFocused: Bool
    /// 侧栏是否接管 ↑↓。点过侧栏后为 true，点搜索框或详情区后交还方向键。
    @State private var isSidebarKeyActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: UpdateStore, openSettings: (() -> Void)? = nil, initialQuery: String = "") {
        self.store = store
        self.openSettings = openSettings
        _query = State(initialValue: initialQuery)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 240)
                .background(
                    SidebarKeyMonitor(
                        isActive: isSidebarKeyActive
                            && !store.isJobSheetPresented
                            && !store.isSelfUpdatePresented,
                        onMove: moveSidebarSelection
                    )
                )
        } detail: {
            detailColumn
                .simultaneousGesture(TapGesture().onEnded { isSidebarKeyActive = false })
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: isSearchFocused) { focused in
            if focused { isSidebarKeyActive = false }
        }
        .sheet(isPresented: $store.isJobSheetPresented) {
            UpgradeSheet(store: store)
        }
        .sheet(isPresented: $store.isSelfUpdatePresented) {
            SelfUpdateSheet(store: store)
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("应用")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(SidebarNav.allCases) { nav in
                SidebarNavRow(
                    nav: nav,
                    count: count(for: nav),
                    isSelected: selection == nav
                ) {
                    select(nav)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.lastCheckedText)
                if store.isShowingCachedResult {
                    Text("显示的是缓存结果")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(sidebarGlow)
    }

    /// 侧栏顶部的一抹渐变。它只做品牌识别，不参与任何状态表达。
    private var sidebarGlow: some View {
        VStack {
            LinearGradient(
                colors: [UpdraftStyle.accentSecondary.opacity(0.13), UpdraftStyle.accent.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 150)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func count(for nav: SidebarNav) -> Int {
        switch nav {
        case .all: return store.updates.count
        case .updateAvailable: return store.updateCount
        case .upToDate: return store.upToDateCount
        case .unsupported: return store.unsupportedCount
        }
    }

    private func select(_ nav: SidebarNav) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            selection = nav
        }
        isSidebarKeyActive = true
    }

    /// 方向键在侧栏内移动选中项，首尾不环绕——与 macOS 原生侧栏一致。
    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        let offset: Int
        switch direction {
        case .up: offset = -1
        case .down: offset = 1
        default: return
        }

        let target = selection.advanced(by: offset)
        guard target != selection else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            selection = target
        }
    }

    // MARK: - 详情列

    private var detailColumn: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let notice = store.recoveryNotice {
                recoveryBanner(notice)
                Divider()
            }
            if case .updateAvailable(let release) = store.selfStatus {
                selfUpdateBanner(release)
                Divider()
            }
            content
            Divider()
            actionBar
        }
    }

    // MARK: - 筛选

    /// 当前筛选结果。查询词为空时就是全量。
    private var filteredUpdates: [AppUpdate] {
        AppSearch.filter(store.updates, query: query)
    }

    /// 侧栏选中项 × 搜索词的交集。
    private var visibleUpdates: [AppUpdate] {
        guard let group = selection.group else { return filteredUpdates }
        return filteredUpdates.filter { $0.group == group }
    }

    private var isFiltering: Bool { !AppSearch.tokenize(query).isEmpty }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 筛选后仍能自动完成的条目数，决定「升级这 N 个」是否出现。
    private var visibleAutomatedCount: Int {
        UpdateStore.automatedCandidates(in: visibleUpdates.filter { $0.group == .updateAvailable }).count
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(toolbarTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(toolbarSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            searchField

            if let notice = store.brewNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(notice)
            }

            Button {
                Task { await store.check() }
            } label: {
                HStack(spacing: 5) {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var toolbarTitle: String {
        isFiltering ? "搜索“\(trimmedQuery)”" : selection.title
    }

    private var toolbarSubtitle: String {
        if !store.statusMessage.isEmpty { return store.statusMessage }
        if store.updates.isEmpty { return "尚未检查" }
        if isFiltering { return "命中 \(filteredUpdates.count) / 共 \(store.updates.count)" }
        switch selection {
        case .all: return "\(store.updates.count) 个应用"
        case .updateAvailable:
            return visibleAutomatedCount > 0 ? "\(store.updateCount) 个应用 · \(visibleAutomatedCount) 个可自动升级" : "\(store.updateCount) 个应用"
        case .upToDate: return "\(store.upToDateCount) 个应用"
        case .unsupported: return "\(store.unsupportedCount) 个应用"
        }
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
        .frame(width: 170)
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

    // MARK: - 横幅

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
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [UpdraftStyle.accent.opacity(0.12), UpdraftStyle.accentSecondary.opacity(0.05), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if store.updates.isEmpty {
            emptyState
        } else if visibleUpdates.isEmpty {
            noMatchState
        } else {
            List {
                ForEach(Array(visibleUpdates.enumerated()), id: \.element.id) { index, update in
                    AppRowView(update: update, store: store)
                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(min(Double(index), 8) * 0.025), value: visibleUpdates.map(\.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
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

    /// 当前侧栏分组（叠加搜索后）零命中。
    ///
    /// 必须与 `emptyState`（尚未检查）在文案上分得开：一个说「没搜到/这个分组是空的」，
    /// 一个说「还没查过」。混成一句的话，用户会以为应用真的没了。
    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: isFiltering ? "magnifyingglass" : selection.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(noMatchTitle)
                .font(.system(size: 13, weight: .medium))
            Text(noMatchHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if isFiltering {
                Button("清除筛选") { query = "" }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchTitle: String {
        if isFiltering { return "没有匹配“\(trimmedQuery)”的应用" }
        return "没有\(selection.title)的应用"
    }

    private var noMatchHint: String {
        if isFiltering { return "已扫描 \(store.updates.count) 个应用，换个词试试" }
        switch selection {
        case .updateAvailable: return "全部应用都已是最新"
        case .all, .upToDate, .unsupported: return ""
        }
    }

    // MARK: - 底部操作条

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let job = store.job, job.isRunning {
                GradientProgressBar(value: job.progress)
                Text(job.phase?.phase.title ?? "执行中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("第 \(job.currentIndex + 1) / \(job.items.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                Text(actionBarSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let job = store.job, job.isRunning {
                Button(job.cancelRequested ? "正在停止…" : "取消升级") { store.cancelJob() }
                    .controlSize(.small)
                    .disabled(job.cancelRequested)
                    .help("当前应用完成后停止，不中断正在进行的安装")
            }

            if store.job != nil {
                Button("查看日志") { store.isJobSheetPresented = true }
                    .controlSize(.small)
            }

            if visibleAutomatedCount > 0, store.job?.isRunning != true {
                Button(isFiltering || selection != .updateAvailable ? "升级这 \(visibleAutomatedCount) 个" : "全部升级") {
                    store.startUpgradeAll(visible: filteredUpdates)
                }
                .buttonStyle(UpgradeButtonStyle())
                .disabled(store.isBusy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var actionBarSummary: String {
        if store.updates.isEmpty { return "尚未检查" }
        if store.updateCount == 0 { return "全部应用已是最新" }
        return "\(store.updateCount) 个应用可更新"
    }
}

/// 侧栏条目。自绘而不是用 List 的 selection：系统高亮只在列表获得焦点时着色，
/// 且固定走系统强调色；这里需要「选中即紫蓝渐变」，和主按钮保持同一套语气。
private struct SidebarNavRow: View {
    let nav: SidebarNav
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isHot: Bool { nav == .updateAvailable && count > 0 }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: nav.symbol)
                .font(.system(size: 13))
                .frame(width: 17)
                .foregroundStyle(isSelected ? UpdraftStyle.accent : iconTint)

            Text(nav.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(.primary)

            Spacer(minLength: 6)

            Text("\(count)")
                .font(.system(size: 11, weight: isHot ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? UpdraftStyle.accent : (isHot ? .orange : .secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    isSelected
                        ? AnyShapeStyle(UpdraftStyle.accent.opacity(0.14))
                        : AnyShapeStyle(isHot ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08)),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: action)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { action() }
    }

    private var iconTint: Color {
        switch nav {
        case .all: return UpdraftStyle.accent
        case .updateAvailable: return .orange
        case .upToDate: return .green
        case .unsupported: return .secondary
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if isSelected {
            shape
                .fill(
                    LinearGradient(
                        colors: [UpdraftStyle.accent.opacity(0.18), UpdraftStyle.accentSecondary.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(shape.stroke(UpdraftStyle.accent.opacity(0.20), lineWidth: 0.8))
        } else if isHovering {
            shape.fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }
}

/// 自绘侧栏收 ↑↓。
///
/// 不用 `.onMoveCommand`：焦点落在 SwiftUI 自绘行上时，AppKit 并不把方向键交给它
/// （窗口的 first responder 仍是窗口本身）。本地事件监听只在本 App 内生效，且只在
/// `isActive`——也就是刚点过侧栏、还没有去碰搜索框或详情区——时才消费方向键。
private struct SidebarKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let onMove: (MoveCommandDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.host = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        weak var host: NSView?
        var isActive = false
        var onMove: ((MoveCommandDirection) -> Void)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard self.isActive,
                      let host = self.host,
                      event.window === host.window else { return event }
                // 搜索框正在输入时，方向键属于文本光标。
                if event.window?.firstResponder is NSTextView { return event }

                let direction: MoveCommandDirection?
                switch event.keyCode {
                case 126: direction = .up
                case 125: direction = .down
                default: direction = nil
                }
                guard let direction else { return event }
                self.onMove?(direction)
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { uninstall() }
    }
}
