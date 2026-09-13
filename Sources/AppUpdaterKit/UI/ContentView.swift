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
            statsRow
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $store.job) { _ in
            UpgradeSheet(store: store)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("App 更新")
                    .font(.system(size: 15, weight: .medium))
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if !store.brewAvailable {
                Label("未找到 Homebrew", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if store.automatedUpdateCount > 1, store.job?.isRunning != true {
                Button("全部升级") {
                    store.requestUpgradeAll()
                }
                .disabled(store.isChecking)
            }

            Button {
                Task { await store.check() }
            } label: {
                HStack(spacing: 6) {
                    if store.isChecking {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text(store.isChecking ? "检查中…" : "重新检查")
                }
                .frame(minWidth: 68)
            }
            .disabled(store.isChecking || store.job?.isRunning == true)
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
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
        } else {
            List {
                ForEach(UpdateGroup.allCases) { group in
                    let items = store.updates(in: group)
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
            Text(store.isChecking ? "正在检查…" : "还没有结果")
                .font(.system(size: 13, weight: .medium))
            Text("点右上角「重新检查」开始扫描已安装的应用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
