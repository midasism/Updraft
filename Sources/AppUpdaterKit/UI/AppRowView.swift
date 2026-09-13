import AppKit
import SwiftUI

struct AppRowView: View {
    let update: AppUpdate
    @ObservedObject var store: UpdateStore

    private var isUpgrading: Bool {
        if case .homebrewCask(let token) = update.app.source {
            return store.upgradingToken == token
        }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(update.detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            action
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("在访达中显示") { store.reveal(update.app) }
            if let feed = feedURL {
                Button("复制更新源地址") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(feed.absoluteString, forType: .string)
                }
            }
        }
    }

    private var feedURL: URL? {
        switch update.app.source {
        case .sparkle(let url): return url
        default: return nil
        }
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(iconBackground)
            .frame(width: 32, height: 32)
            .overlay(
                Text(update.app.initial)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconForeground)
            )
    }

    private var iconBackground: Color {
        switch update.group {
        case .updateAvailable: return Color.orange.opacity(0.16)
        case .upToDate: return Color.green.opacity(0.14)
        case .unsupported: return Color.secondary.opacity(0.12)
        }
    }

    private var iconForeground: Color {
        switch update.group {
        case .updateAvailable: return Color.orange
        case .upToDate: return Color.green
        case .unsupported: return Color.secondary
        }
    }

    @ViewBuilder
    private var action: some View {
        if isUpgrading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 56)
        } else if case .updateAvailable = update.result {
            if store.canUpgrade(update) {
                Button("升级") {
                    Task { await store.upgrade(update) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if hasDownload {
                Button("下载") {
                    store.openDownload(for: update)
                }
                .controlSize(.small)
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hasDownload: Bool {
        guard case .updateAvailable(_, let url, let notes, _) = update.result else { return false }
        return url != nil || notes != nil
    }
}

struct LogSheet: View {
    @ObservedObject var store: UpdateStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("升级日志")
                    .font(.system(size: 14, weight: .medium))
                if let token = store.upgradingToken {
                    Text(token)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.upgradingToken != nil {
                    ProgressView().controlSize(.small)
                }
                Button("关闭") { store.isShowingLog = false }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(store.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 620, height: 420)
    }
}
