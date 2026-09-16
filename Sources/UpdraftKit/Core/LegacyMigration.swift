import Foundation

/// 一次性迁移：v0.3.x 时代这个工具叫 **AppUpdater**、Bundle ID 是 `com.local.appupdater`，
/// v0.4 起对外统一成 **Updraft**，支持目录与 UserDefaults suite 都跟着换了名字。
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
    /// 迁移完成的标记，写在**新** suite 里。
    public static let completedKey = "migration.renamed-from-appupdater"

    /// 幂等入口。
    public static func runIfNeeded() {
        migrateDefaultsIfNeeded()

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

    /// 老 suite 里的设置搬到新 suite。
    ///
    /// 只补新 suite 里**不存在**的键，绝不覆盖已经写进去的值。
    /// 不遍历固定的键名清单，是因为这份清单在 `AppSettings` 里是 private 的，
    /// 抄一份过来迟早会漂；而那个 suite 里的键全是我们自己写的，没有误搬的风险。
    @discardableResult
    public static func migrateDefaults(
        from legacySuiteName: String = SelfUpdateIdentity.Legacy.bundleID,
        to suiteName: String = SelfUpdateIdentity.bundleID
    ) -> Bool {
        guard let legacy = UserDefaults(suiteName: legacySuiteName),
              let current = UserDefaults(suiteName: suiteName) else { return false }
        guard current.bool(forKey: completedKey) == false else { return false }

        let values = legacy.dictionaryRepresentation()
        for (key, value) in values where current.object(forKey: key) == nil {
            current.set(value, forKey: key)
        }
        current.set(true, forKey: completedKey)
        return true
    }

    private static func migrateDefaultsIfNeeded() {
        migrateDefaults()
    }
}
