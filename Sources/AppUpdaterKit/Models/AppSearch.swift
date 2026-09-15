import Foundation

/// 列表筛选的纯判定逻辑。
///
/// 刻意不放进 `UpdateStore`，也不放进视图：它只回答「给定一条记录和一个查询词，
/// 匹不匹配」，没有状态、不碰网络、不认识 SwiftUI。这样这批边界断言不必借 GUI
/// 与真机就能密集地写。与 `CheckPlanner`（只回答「现在该不该查」）是同一个路子。
public enum AppSearch {
    /// 把查询词按空白切成 token。
    ///
    /// 空数组表示「不筛选」——注意是不过滤，不是过滤掉全部。这是最容易写反的一处。
    /// `split` 顺带办掉了裁首尾空白与合并连续空白两件事，不需要额外 trim。
    public static func tokenize(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 每个 token 都要在「名称或 Bundle ID」里命中才算通过。
    ///
    /// 允许不同 token 命中不同字段：`"cherry com.kangfenmao"` 也成立。
    public static func matches(_ update: AppUpdate, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let fields = [update.app.name, update.app.bundleID].compactMap { $0 }
        return tokens.allSatisfy { token in
            fields.contains { $0.localizedCaseInsensitiveContains(token) }
        }
    }

    /// 过滤整个列表。查询词为空时原样返回。
    ///
    /// 顺序也不动——沿用 `AppUpdate.listOrder` 已经排好的结果，排序只有那一处定义。
    public static func filter(_ updates: [AppUpdate], query: String) -> [AppUpdate] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return updates }
        return updates.filter { matches($0, tokens: tokens) }
    }
}
