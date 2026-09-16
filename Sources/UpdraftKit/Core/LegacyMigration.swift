import Foundation

/// 一次性迁移：v0.3.x 时代这个工具叫 **AppUpdater**、Bundle ID 是 `com.local.appupdater`，
/// v0.3.4 起对外统一成 **Updraft**，数据目录与 UserDefaults suite 都跟着换了名字。
///
/// 这里把老数据搬到新位置。三条设计要求：
///
/// 1. **幂等**：搬过一次就不再搬（目录以「新目录已存在」判断，设置以标记键判断）。
/// 2. **不拷贝**：同卷 `moveItem` 走的是 rename，1.7 GB 的备份目录也是瞬时的。
/// 3. **失败不拦启动**：任何一步出错都只是放弃这次迁移，老目录原样留着，
///    用户不会因为搬家失败而丢东西或打不开应用。
///
/// 调用时机很关键：必须在**任何路径对象被构造之前**。放在 `main.swift` 顶层、
/// `UpdraftApp.main()` 之前——`StateCache` / `BackupStore` 一旦先跑，读到的就是空目录。
public enum LegacyMigration {
    /// 迁移完成的标记，写在**新**设置域里。
    public static let completedKey = "migration.renamed-from-appupdater"

    /// 幂等入口。
    public static func runIfNeeded() {
        migrateDefaults()

        let fm = FileManager.default
        for searchPath in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let base = fm.urls(for: searchPath, in: .userDomainMask).first else { continue }
            migrateDirectory(
                from: base.appendingPathComponent(
                    SelfUpdateIdentity.Legacy.supportDirectoryName, isDirectory: true
                ),
                to: base.appendingPathComponent(
                    SelfUpdateIdentity.supportDirectoryName, isDirectory: true
                )
            )
        }
    }

    /// 把 `~/Library/Application Support/AppUpdater` 这类目录改名成 `.../Updraft`。
    ///
    /// 新目录已存在就什么都不做——宁可让用户手动看一眼两份目录，也不要合并出四不像。
    /// - Returns: 真的搬了才返回 `true`。
    @discardableResult
    public static func migrateDirectory(from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        guard from.path != to.path,
              fm.fileExists(atPath: from.path),
              !fm.fileExists(atPath: to.path) else { return false }
        do {
            try fm.moveItem(at: from, to: to)
            return true
        } catch {
            return false
        }
    }

    /// 老域里的设置搬到新的设置 suite。
    ///
    /// - 源：老 bundle id `com.local.appupdater`。老版本把 bundle id 当 suite 名，macOS 会
    ///   拒绝它，所以老的设置实际落在**老 app 自己的域**里——域名同样是 `com.local.appupdater`，
    ///   就是同一个 plist。这个默认值读到的正是那些值。
    /// - 目标：`SelfUpdateIdentity.settingsSuiteName`，必须与 `AppSettings.suiteName` 同源，
    ///   否则等于把设置搬进一个没人读的角落。
    ///
    /// 只补新域里**不存在**的键，绝不覆盖已经写进去的值。
    /// - Returns: 真的搬了至少一个键才返回 `true`。
    @discardableResult
    public static func migrateDefaults(
        from legacySuiteName: String = SelfUpdateIdentity.Legacy.bundleID,
        to suiteName: String = SelfUpdateIdentity.settingsSuiteName
    ) -> Bool {
        // 这一步同时也是护栏：suite 名一旦撞上自己的 bundle id，这里会拿到 nil，
        // 迁移会静静地什么都不做。`SelfUpdateIdentity.settingsSuiteName` 保证不会。
        guard let current = UserDefaults(suiteName: suiteName) else { return false }
        guard current.bool(forKey: completedKey) == false else { return false }

        // 用 `persistentDomain` 而不是 `UserDefaults(suiteName:).dictionaryRepresentation()`：
        // 后者返回的是**搜索列表**，会把 NSGlobalDomain 的六十多个系统键（语言、触控板手势…）
        // 一起端上来（实测同一份 suite：64 个 vs 我们自己的 2 个）。搬设置不该捎上这些。
        let values = UserDefaults.standard.persistentDomain(forName: legacySuiteName) ?? [:]
        var copied = 0
        for (key, value) in values where current.object(forKey: key) == nil {
            current.set(value, forKey: key)
            copied += 1
        }
        // 老域不存在也照样打标记：老用户机器上可能压根没写过设置，
        // 不打标记的话每次启动都要再查一遍。
        current.set(true, forKey: completedKey)
        return copied > 0
    }
}
