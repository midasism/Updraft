import Foundation

/// 安装包下载器。
///
/// 用 `URLSessionDownloadDelegate` 而不是 `data(for:)`——IINA 的包 104 MB、
/// ToDesk 的包 359 MB，走内存会很难看；委托回调还能顺带把下载进度吐给界面。
public struct PackageDownloader: Sendable {
    public enum DownloadError: LocalizedError {
        case badStatus(Int)
        case emptyResponse
        case notWritten

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "服务器返回 HTTP \(code)"
            case .emptyResponse: return "下载没有拿到任何数据"
            case .notWritten: return "下载文件未能写入磁盘"
            }
        }
    }

    /// 单个安装包的超时时间。大包给足 20 分钟，单次请求 60 秒无进展即失败。
    private let resourceTimeout: TimeInterval

    public init(resourceTimeout: TimeInterval = 1200) {
        self.resourceTimeout = resourceTimeout
    }

    /// 下载到指定路径。`onProgress` 的第二个参数在服务器未给出总长度时为 -1。
    public func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": "AppUpdater/0.2 (macOS)"]

        let delegate = Delegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        try await delegate.start(session: session, url: url)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw DownloadError.notWritten
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let onProgress: (@Sendable (Int64, Int64) -> Void)?

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(destination: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) {
            self.destination = destination
            self.onProgress = onProgress
        }

        func start(session: URLSession, url: URL) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.downloadTask(with: url).resume()
            }
        }

        private func finish(_ error: Error?) {
            lock.lock()
            let pending = continuation
            let accumulated = failure
            continuation = nil
            lock.unlock()

            guard let pending else { return }
            if let error {
                pending.resume(throwing: error)
            } else if let accumulated {
                pending.resume(throwing: accumulated)
            } else {
                pending.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // location 指向的是临时文件，本回调返回后就会被清理，必须在这里同步搬走。
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                record(PackageDownloader.DownloadError.badStatus(http.statusCode))
                return
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                record(PackageDownloader.DownloadError.emptyResponse)
                return
            }

            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: location, to: destination)
            } catch {
                record(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(error)
        }

        private func record(_ error: Error) {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }
}
