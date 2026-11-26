import AppKit
import SwiftUI

/// 主窗口的视觉基元。颜色保持系统语义；渐变与材质只用于状态反馈，不给整窗铺彩色。
enum UpdraftStyle {
    static let accent = Color(red: 0.36, green: 0.35, blue: 0.88)
    static let accentSecondary = Color(red: 0.49, green: 0.23, blue: 0.93)

    static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let versionGradient = LinearGradient(
        colors: [Color(red: 0.90, green: 0.48, blue: 0.10), Color(red: 0.95, green: 0.34, blue: 0.23)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// 升级主按钮：渐变填充 + 按下回弹。系统 `.borderedProminent` 只有一个平色，
/// 和列表里「升级到哪个版本」的强调色串不成一套。
struct UpgradeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(UpdraftStyle.accentGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(
                color: UpdraftStyle.accent.opacity(isEnabled ? 0.30 : 0),
                radius: configuration.isPressed ? 2 : 5,
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 操作条上的渐变进度条。系统线性进度只有一个平色，这里用胶囊 + 渐变保持同一套强调色。
struct GradientProgressBar: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(UpdraftStyle.accentGradient)
                    .frame(width: max(geo.size.width * min(max(value, 0), 1), value > 0 ? 4 : 0))
            }
        }
        .frame(width: 110, height: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: value)
        .accessibilityLabel("升级进度")
        .accessibilityValue("\(Int(value * 100))%")
    }
}

/// `NSWorkspace.icon(forFile:)` 是磁盘 + 系统服务往返，列表复用时不能每行重取。
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    @MainActor
    static func icon(for path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        // 纯命令行 cask 指向 Caskroom 目录，取出来的只是文件夹图标，不如不用。
        guard path.hasSuffix(".app") else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        icons[path] = image
        return image
    }
}

struct AppRowView: View {
    let update: AppUpdate
    @ObservedObject var store: UpdateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(update.app.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if update.result.release?.edSignature != nil, update.app.canVerifySignature {
                        Label("已签名", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                            .help("更新源提供 Ed25519 签名，安装前会校验")
                    }
                }
                metadata
            }

            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
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

    @ViewBuilder
    private var metadata: some View {
        HStack(spacing: 6) {
            if let release = update.result.release {
                Text(release.upgradeFrom(actualVersion: update.app.currentVersion))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(release.version)
                    .fontWeight(.semibold)
                    .foregroundStyle(UpdraftStyle.versionGradient)
                if let size = release.size, size > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(AppUpdate.formatBytes(size))
                        .foregroundStyle(.secondary)
                }
                if let actual = update.app.currentVersion, release.hasStaleLedger(actualVersion: actual) {
                    Text("实际已装 \(actual)")
                        .foregroundStyle(.orange)
                }
            } else {
                Text(update.detailText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(update.app.source.badge)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.09), in: Capsule())
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? UpdraftStyle.accent.opacity(0.24) : Color.primary.opacity(0.055), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(isHovering ? 0.11 : 0.045), radius: isHovering ? 9 : 3, y: isHovering ? 3 : 1)
            .offset(y: isHovering ? -1 : 0)
    }

    private var feedURL: URL? {
        switch update.app.source {
        case .sparkle(let url): return url
        default: return nil
        }
    }

    private var icon: some View {
        Group {
            if let image = AppIconCache.icon(for: update.app.path.path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBackground)
                    .overlay(
                        Text(update.app.initial)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(iconForeground)
                    )
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
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
            HStack(spacing: 7) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(UpdraftStyle.accent)
                    .frame(width: 72)
                Text(store.job?.phase?.phase.title ?? "执行中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .trailing)
        } else if case .succeeded = finishedState {
            Label("已升级", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else if case .failed(let reason) = finishedState {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        } else if case .skipped(let reason) = finishedState {
            Label(reason, systemImage: "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if case .updateAvailable = update.result {
            switch action {
            case .homebrew, .replaceBundle:
                Button(action.buttonTitle) { store.startUpgrade(update) }
                    .buttonStyle(UpgradeButtonStyle())
                    .disabled(store.job?.isRunning == true)

            case .openInstaller, .openDownload:
                Button(action.buttonTitle) { store.openDownload(for: update) }
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
