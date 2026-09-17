/// `ProcessRunner.stream` 的流事件。
///
/// 替代原来的 `AsyncStream<String>`：输出内容和退出状态分开传递，
/// 消费方不再需要做字符串匹配来判断进程是否成功。
public enum StreamEvent: Sendable {
    /// 一段 stdout / stderr 输出。
    case output(String)
    /// 进程已退出。`exitCode == 0` 表示成功。
    case finished(exitCode: Int32)

    /// 便捷：取出输出文本，非 `.output` 时返回 nil。
    public var text: String? {
        if case .output(let s) = self { return s }
        return nil
    }
}
