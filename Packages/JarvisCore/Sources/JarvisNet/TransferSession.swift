import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uploads and downloads with progress, on top of delegate based URLSession tasks (the async convenience APIs
/// do not report progress).
final class TransferSession: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class Job {
        var progress: (Double) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var fileURL: URL?
        var suggestedName: String = "download"
        var cont: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var downloadCont: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        var moveError: Error?
        init(progress: @escaping (Double) -> Void) { self.progress = progress }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
                cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private func job(_ task: URLSessionTask) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[task.taskIdentifier] }
    private func remove(_ task: URLSessionTask) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs.removeValue(forKey: task.taskIdentifier) }

    func upload(_ request: URLRequest, fromFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        let task = session.uploadTask(with: request, fromFile: fromFile)
        let j = Job(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                j.cont = c
                lock.lock(); jobs[task.taskIdentifier] = j; lock.unlock()
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func download(_ request: URLRequest, suggestedName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: request)
        let j = Job(progress: progress); j.suggestedName = suggestedName
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                j.downloadCont = c
                lock.lock(); jobs[task.taskIdentifier] = j; lock.unlock()
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    // MARK: delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        job(task)?.progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        job(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        job(dataTask)?.data.append(data)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        job(downloadTask)?.progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let j = job(downloadTask) else { return }
        // the system deletes `location` when this returns: move it now
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(j.suggestedName)
            try FileManager.default.moveItem(at: location, to: dest)
            j.fileURL = dest
        } catch { j.moveError = error }
        j.response = downloadTask.response as? HTTPURLResponse
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let j = remove(task) else { return }
        if let error = error {
            if (error as? URLError)?.code == .cancelled { j.cont?.resume(throwing: CancellationError()); j.downloadCont?.resume(throwing: CancellationError()) }
            else {
                let e = ApiError.offline(ApiClient.describe(error))
                j.cont?.resume(throwing: e); j.downloadCont?.resume(throwing: e)
            }
            return
        }
        let http = j.response ?? (task.response as? HTTPURLResponse)
        guard let http = http else {
            let e = ApiError.offline("no HTTP response"); j.cont?.resume(throwing: e); j.downloadCont?.resume(throwing: e); return
        }
        if let c = j.cont { c.resume(returning: (j.data, http)); return }
        if let c = j.downloadCont {
            if let url = j.fileURL { j.progress(1); c.resume(returning: (url, http)) }
            else { c.resume(throwing: j.moveError ?? ApiError.offline("download failed")) }
        }
    }
}
