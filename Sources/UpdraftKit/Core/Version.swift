import Foundation

/// 点分版本号。处理 `v1.2.3`、`1.0`、`3.39.11,dy27whJwwmb,a`、`2.1.0-beta.2` 这类写法，
/// 只取每段的数字前缀参与比较，后缀仅用于区分正式版与预发布版。
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let raw: String
    public let numbers: [Int]
    public let suffix: String?

    public init(_ string: String) {
        raw = string

        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }

        let halves = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let head = halves.first.map(String.init) ?? ""
        if halves.count > 1, !halves[1].isEmpty {
            suffix = String(halves[1])
        } else {
            suffix = nil
        }

        let parsed = head.split(separator: ".").map { segment -> Int in
            let digits = segment.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        numbers = parsed.isEmpty ? [0] : parsed
    }

    public var description: String { raw }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        // 数字段完全相同（1.0 与 1.0.0 视为同一版本），带后缀者视为更早的预发布版。
        switch (lhs.suffix, rhs.suffix) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let left), .some(let right)): return left < right
        }
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// 版本比对入口。优先用构建号整数，回退到点分版本号；两者都不可用时返回 false，绝不猜测。
public enum VersionComparison {
    public struct Candidate: Sendable {
        public let shortVersion: String?
        public let buildVersion: String?

        public init(shortVersion: String?, buildVersion: String?) {
            self.shortVersion = shortVersion
            self.buildVersion = buildVersion
        }
    }

    public static func isNewer(latest: Candidate, than current: Candidate) -> Bool {
        let latestBuild = latest.buildVersion.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let currentBuild = current.buildVersion.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let latestBuild, let currentBuild, latestBuild != currentBuild {
            return latestBuild > currentBuild
        }

        let latestShort = nonEmpty(latest.shortVersion)
        let currentShort = nonEmpty(current.shortVersion)
        if let latestShort, let currentShort {
            return Version(latestShort) > Version(currentShort)
        }

        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
