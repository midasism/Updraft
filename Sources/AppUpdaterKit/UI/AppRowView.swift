import AppKit
import SwiftUI

struct AppRowView: View {
    let update: AppUpdate
    @ObservedObject var store: UpdateStore

    /// 本条正在被升级任务处理。
    private var isUpgrading: Bool {
        guard let job = store.job, job.isRunning else { return false }
        return job.items.contains { $0.id == update.id && $0.state == .running }
    }

    /// 本条已在本轮任务里处理完。
    private var finishedState: UpgradeJob.ItemState? {
        guard let job = store.job else { return nil }
        return job.items.first { $0.id == update.id }?.state
    }

    private var action: InstallAction { update.installAction }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(update.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if update.result.release?.edSignature != nil, update.app.canVerifySignature {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .help("更新源提供 Ed25519 签名，安装前会校验")
                    }
                }
            }

            Spacer(minLength: 12)

            trailing
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
            if update.result.release?.releaseNotesURL != nil {
                Button("查看更新说明") { store.openReleaseNotes(update) }
            }
            if update.result.release?.downloadURL != nil {
                Button("在浏览器中打开下载页") { store.openDownload(for: update) }
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
    private var trailing: some View {
        if isUpgrading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(store.job?.phase?.phase.title ?? "执行中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .trailing)
        } else if case .succeeded = finishedState {
            Label("已升级", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else if case .failed(let reason) = finishedState {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        } else if case .updateAvailable = update.result {
            switch action {
            case .homebrew, .replaceBundle:
                Button(action.buttonTitle) {
                    store.requestUpgrade(update)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.job?.isRunning == true)

            case .openInstaller, .openDownload:
                Button(action.buttonTitle) {
                    store.openDownload(for: update)
                }
                .controlSize(.small)
                .disabled(store.job?.isRunning == true)

            case .manual:
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
