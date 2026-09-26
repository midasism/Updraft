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
        HStack(spacing: Theme.Spacing.sm) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name)
                    .font(Theme.Fonts.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(update.detailText)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if update.result.release?.edSignature != nil, update.app.canVerifySignature {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.success)
                            .help("更新源提供 Ed25519 签名，安装前会校验")
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            trailing
        }
        .padding(.vertical, 5)
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
            if update.ignoredVersion != nil {
                Button("取消忽略") { store.unignoreVersion(of: update) }
            } else if let release = update.result.release {
                Button("忽略这个版本 \(release.version)") { store.ignoreVersion(of: update) }
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
        RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous)
            .fill(iconBackground)
            .frame(width: 34, height: 34)
            .overlay(
                Text(update.app.initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconForeground)
            )
    }

    private var iconBackground: Color {
        switch update.group {
        case .updateAvailable: return Theme.Colors.attention.opacity(0.14)
        case .upToDate: return Theme.Colors.success.opacity(0.12)
        case .ignored, .unsupported: return Color.secondary.opacity(0.10)
        }
    }

    private var iconForeground: Color {
        switch update.group {
        case .updateAvailable: return Theme.Colors.attention
        case .upToDate: return Theme.Colors.success
        case .ignored, .unsupported: return Color.secondary
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isUpgrading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(store.job?.phase?.phase.title ?? "执行中")
                    .font(Theme.Fonts.note)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .trailing)
        } else if case .succeeded = finishedState {
            Label("已升级", systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.note)
                .foregroundStyle(Theme.Colors.success)
                .labelStyle(.titleAndIcon)
        } else if case .failed(let reason) = finishedState {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.note)
                .foregroundStyle(Theme.Colors.attention)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        } else if case .updateAvailable = update.result, update.ignoredVersion == nil {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.job?.isRunning == true)

            case .manual:
                Text("—")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
