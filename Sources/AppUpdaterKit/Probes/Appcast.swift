import Foundation

/// appcast.xml 里的一个版本条目。
public struct AppcastItem: Equatable, Sendable {
    public var shortVersion: String?
    public var buildVersion: String?
    public var downloadURL: URL?
    public var size: Int64?
    public var releaseNotesURL: URL?
    public var minimumSystemVersion: String?

    public init(
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        downloadURL: URL? = nil,
        size: Int64? = nil,
        releaseNotesURL: URL? = nil,
        minimumSystemVersion: String? = nil
    ) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.downloadURL = downloadURL
        self.size = size
        self.releaseNotesURL = releaseNotesURL
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// 版本号缺失时用 RSS 的 `<title>` 兜底。
    public var titleFallback: String? = nil

    public var displayVersion: String? {
        shortVersion ?? titleFallback ?? buildVersion
    }

    /// 系统版本不够的话 Sparkle 自己也会跳过这个条目，我们提前过滤，避免报出装不上的"更新"。
    public func isEligible(for operatingSystem: OperatingSystemVersion) -> Bool {
        guard let raw = minimumSystemVersion, !raw.isEmpty else { return true }
        let required = Version(raw)
        let current = [operatingSystem.majorVersion, operatingSystem.minorVersion, operatingSystem.patchVersion]
        let requiredNumbers = required.numbers
        for index in 0..<max(requiredNumbers.count, current.count) {
            let left = index < requiredNumbers.count ? requiredNumbers[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left < right }
        }
        return true
    }
}

public struct Appcast: Equatable, Sendable {
    public var channelTitle: String?
    public var items: [AppcastItem]

    public init(channelTitle: String? = nil, items: [AppcastItem] = []) {
        self.channelTitle = channelTitle
        self.items = items
    }

    /// 挑出最新的条目：优先按构建号整数比，回退到点分版本号。
    public func latestItem(eligibleFor operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> AppcastItem? {
        let eligible = items.filter { $0.isEligible(for: operatingSystem) }
        let pool = eligible.isEmpty ? items : eligible

        let withBuild = pool.compactMap { item -> (AppcastItem, Int)? in
            guard let raw = item.buildVersion?.trimmingCharacters(in: .whitespaces), let value = Int(raw) else { return nil }
            return (item, value)
        }
        if let best = withBuild.max(by: { $0.1 < $1.1 }) {
            return best.0
        }

        return pool.max { left, right in
            Version(left.displayVersion ?? "") < Version(right.displayVersion ?? "")
        }
    }
}

/// 基于 `XMLParser` 的 appcast 解析。
///
/// 关闭命名空间处理后，`elementName` 会保留 `sparkle:` 前缀，因此按前缀归一化即可，
/// 不必为解析引入第三方 XML 依赖。
public enum AppcastParser {
    public static func parse(_ xml: String) -> Appcast {
        guard let data = xml.data(using: .utf8) else { return Appcast() }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return Appcast(channelTitle: delegate.channelTitle, items: delegate.items)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var channelTitle: String?
        var items: [AppcastItem] = []

        private var current: AppcastItem?
        private var currentTitle: String?
        private var buffer = ""

        private func normalized(_ name: String) -> String {
            let bare = name.split(separator: ":").last.map(String.init) ?? name
            return bare.lowercased()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            buffer = ""

            switch normalized(elementName) {
            case "item":
                current = AppcastItem()
                currentTitle = nil

            case "enclosure":
                guard current != nil else { break }
                if let raw = attributeDict["url"], let url = URL(string: raw) {
                    current?.downloadURL = url
                }
                if let raw = attributeDict["length"], let size = Int64(raw) {
                    current?.size = size
                }
                if let raw = attributeDict["sparkle:shortVersionString"] {
                    current?.shortVersion = raw
                }
                if let raw = attributeDict["sparkle:version"], current?.buildVersion == nil {
                    current?.buildVersion = raw
                }

            case "releasenoteslink":
                guard current != nil else { break }
                if let raw = attributeDict["sparkle:url"] ?? attributeDict["url"],
                   let url = URL(string: raw) {
                    current?.releaseNotesURL = url
                }

            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""

            switch normalized(elementName) {
            case "item":
                if var item = current {
                    item.titleFallback = currentTitle
                    items.append(item)
                }
                current = nil
                currentTitle = nil

            case "title":
                if current != nil {
                    currentTitle = text.isEmpty ? nil : text
                } else if !text.isEmpty {
                    channelTitle = text
                }

            case "shortversionstring":
                if current != nil, !text.isEmpty { current?.shortVersion = text }

            case "version":
                // 只认条目内的 sparkle:version，channel 级的版本号代表不了任何东西。
                if current != nil, !text.isEmpty { current?.buildVersion = text }

            case "minimumsystemversion":
                if current != nil, !text.isEmpty { current?.minimumSystemVersion = text }

            case "releasenoteslink":
                if current != nil, current?.releaseNotesURL == nil, !text.isEmpty,
                   let url = URL(string: text) {
                    current?.releaseNotesURL = url
                }

            default:
                break
            }
        }
    }
}
