import Foundation

/// 安装中断恢复与文件系统工具。
public struct RecoveryReport: Sendable {
    /// 从中间态里抢救回来的应用。
    public var rescuedApps: [String] = []
    /// 清掉的残留文件。
    public var removedArtifacts: [String] = []
    /// 需要人工处理的情况。绝不自作主张删除。
    public var needsAttention: [String] = []

    public var isEmpty: Bool {
        rescuedApps.isEmpty && removedArtifacts.isEmpty && needsAttention.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !rescuedApps.isEmpty {
            parts.append("已恢复 \(rescuedApps.joined(separator: "、"))")
        }
        if !removedArtifacts.isEmpty {
            parts.append("清理了 \(removedArtifacts.count) 个残留文件")
        }
        parts.append(contentsOf: needsAttention)
        return parts.joined(separator: "；")
    }
}

extension Installer {
    /// 换包中间态文件名的结构。
    enum ArtifactKind {
        /// `.<名字>.<token>.new.app` —— 待就位的新包。
        case incoming
        /// `.<名字>.<token>.old.app` —— 被换下来的旧包，回滚的唯一依据。
        case displaced
        /// `.<名字>.app.broken-<token>` —— 回滚过程中被挪开的坏包。
        case broken
    }

    /// 解析隐藏的中间态文件名，顺便挡住所有无关的隐藏文件。
    static func classifyArtifact(_ name: String) -> (stem: String, kind: ArtifactKind)? {
        // `._Foo` 是 AppleDouble 伴生文件，不是我们造的中间态。
        guard name.hasPrefix("."), !name.hasPrefix("._") else { return nil }
        let body = String(name.dropFirst())
        guard !body.isEmpty else { return nil }

        for (suffix, kind) in [(".new.app", ArtifactKind.incoming), (".old.app", ArtifactKind.displaced)] {
            guard body.hasSuffix(suffix) else { continue }
            let head = String(body.dropLast(suffix.count))     // 形如 "Rectangle.38144E15"
            let pieces = head.split(separator: ".")
            guard pieces.count >= 2, let token = pieces.last, isArtifactToken(token) else { return nil }
            let stem = pieces.dropLast().joined(separator: ".")
            return stem.isEmpty ? nil : (stem, kind)
        }

        if let marker = body.range(of: ".app.broken-") {
            let stem = String(body[body.startIndex..<marker.lowerBound])
            let token = String(body[marker.upperBound...])
            guard !stem.isEmpty, isArtifactToken(Substring(token)) else { return nil }
            return (stem, .broken)
        }

        return nil
    }

    /// 换包时用的 token 是 `UUID().uuidString` 的前 8 位。
    static func isArtifactToken(_ value: Substring) -> Bool {
        value.count == 8 && value.allSatisfy(\.isHexDigit)
    }

    /// 一个 `.app` 是否完整可用：Info.plist 能读、Bundle ID 在、可执行文件在。
    static func isHealthyBundle(_ app: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let contents = app.appendingPathComponent("Contents")
        guard let bundleID = plistValue("CFBundleIdentifier", in: app), !bundleID.isEmpty,
              let executable = plistValue("CFBundleExecutable", in: app), !executable.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(
            atPath: contents.appendingPathComponent("MacOS/\(executable)").path
        )
    }

    /// 扫描应用目录，清理（必要时抢救）上一次被中断的安装残留。
    ///
    /// 关键判断：**目标应用是否完好**。
    /// - 目标完好 → 中间态文件都是冗余的，删掉。
    /// - 目标缺失/损坏，但有 `.old.app` → 说明崩溃恰好落在"旧包已挪走、新包未就位"之间，
    ///   把旧包搬回去，用户至少还有能用的应用。
    /// - 目标缺失又没有可用的旧包 → 什么都不删，原样保留并报告，交给人判断。
    @discardableResult
    public static func recoverInterruptedInstalls(
        in roots: [URL] = AppScanner.defaultSearchPaths
    ) -> RecoveryReport {
        let fm = FileManager.default
        var report = RecoveryReport()

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            var grouped: [String: [URL]] = [:]
            for entry in entries {
                guard let parsed = classifyArtifact(entry.lastPathComponent) else { continue }
                grouped[parsed.stem, default: []].append(entry)
            }

            for (stem, artifacts) in grouped {
                let target = root.appendingPathComponent("\(stem).app", isDirectory: true)

                if !isHealthyBundle(target) {
                    let rescueSource = artifacts.first {
                        classifyArtifact($0.lastPathComponent)?.kind == .displaced && isHealthyBundle($0)
                    }

                    guard let rescueSource else {
                        report.needsAttention.append(
                            "\(target.path) 缺失或损坏，残留文件已保留待人工确认：" +
                            artifacts.map(\.lastPathComponent).joined(separator: "、")
                        )
                        continue
                    }

                    if fm.fileExists(atPath: target.path) {
                        try? fm.removeItem(at: target)
                    }
                    if (try? fm.moveItem(at: rescueSource, to: target)) != nil {
                        report.rescuedApps.append(stem)
                    } else {
                        report.needsAttention.append(
                            "\(target.path) 恢复失败，旧版仍保留在 \(rescueSource.path)"
                        )
                        continue
                    }

                    for artifact in artifacts where artifact != rescueSource {
                        if (try? fm.removeItem(at: artifact)) != nil {
                            report.removedArtifacts.append(artifact.lastPathComponent)
                        }
                    }
                    continue
                }

                for artifact in artifacts {
                    if (try? fm.removeItem(at: artifact)) != nil {
                        report.removedArtifacts.append(artifact.lastPathComponent)
                    }
                }
            }
        }

        return report
    }

    /// 清理上次运行留下的工作目录（下载缓存、解包目录）。
    ///
    /// 目录名以创建它的进程 PID 开头：PID 还活着就跳过，因此可以放心地在
    /// 每次安装开始时顺手清一遍，不会误删正在干活的那个。
    @discardableResult
    public static func cleanStaleWorkspaces() -> Int {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let workRoot = base.appendingPathComponent(
            "\(SelfUpdateIdentity.supportDirectoryName)/work",
            isDirectory: true
        )
        guard let entries = try? fm.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            if let dash = name.firstIndex(of: "-"),
               let pid = pid_t(name[name.startIndex..<dash]),
               pid != ProcessInfo.processInfo.processIdentifier,
               kill(pid, 0) == 0 {
                continue    // 那个进程还在跑，别动它的目录
            }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - 文件系统工具

extension Installer {
    /// 工作目录名以 PID 开头，`cleanStaleWorkspaces` 据此判断这个目录的主人还在不在。
    static func makeWorkspace() throws -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent(SelfUpdateIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// 一个 `.app` 包在磁盘上实际占用的字节数。
    static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else {
            return nil
        }

        var total: Int64 = 0
        var sawAnything = false
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            sawAnything = true
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return sawAnything ? total : nil
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
