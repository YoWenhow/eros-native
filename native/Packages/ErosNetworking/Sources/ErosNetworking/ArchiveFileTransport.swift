import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ErosCore

/// Safe transfer diagnostics: never includes a signed URL, headers or response body.
public enum ArchiveFileTransportError: Error, Equatable, Sendable {
    case redirect(Int)
    case unexpectedStatus(Int)
    case invalidResponse
    case htmlResponse
    case invalidZip
    case tooLarge
}

/// File bytes written so far and the best available total. A response length
/// is exact; the site quote is a rounded fallback.
public struct ArchiveByteProgress: Sendable {
    public let received: Int64
    public let expected: Int64?
    public let isEstimated: Bool
    public let delta: Int64
}

struct ArchiveTransferTotal: Equatable, Sendable {
    let bytes: Int64?
    let isEstimated: Bool

    static func choose(responseLength: Int64, contentLength: String?, estimate: Int64?,
                       maximumBytes: UInt64) throws -> Self {
        if responseLength > 0 {
            guard UInt64(responseLength) <= maximumBytes else { throw ArchiveFileTransportError.tooLarge }
            return Self(bytes:responseLength,isEstimated:false)
        }
        if let raw=contentLength?.trimmingCharacters(in:.whitespaces), !raw.isEmpty,
           raw.allSatisfy({ $0.isASCII && $0.isNumber }), let length=Int64(raw), length>0 {
            guard UInt64(length) <= maximumBytes else { throw ArchiveFileTransportError.tooLarge }
            return Self(bytes:length,isEstimated:false)
        }
        if let estimate,estimate>0,UInt64(estimate)<=maximumBytes {
            return Self(bytes:estimate,isEstimated:true)
        }
        return Self(bytes:nil,isEstimated:false)
    }
}

/// Streams the exact ready-page capability to a private file. Each range
/// writes only its own offset and is joined before the caller releases its slots.
public struct ArchiveFileTransport: Sendable {
    public typealias Submit = @Sendable (@escaping @Sendable () -> Void) async throws -> Void

    public static let maximumBytes: UInt64 = 20 * 1024 * 1024 * 1024
    public let maximumBytes: UInt64
    private let configuration: URLSessionConfiguration

    public init(maximumBytes: UInt64 = ArchiveFileTransport.maximumBytes) {
        self.maximumBytes = maximumBytes
        self.configuration = .ephemeral
    }

    init(maximumBytes: UInt64, configuration: URLSessionConfiguration) {
        self.maximumBytes = maximumBytes
        self.configuration = configuration
    }

    public func download(_ prepared: PreparedArchive, in directory: URL, estimatedBytes: Int64? = nil,
                         onProgress: (@Sendable (ArchiveByteProgress) -> Void)? = nil) async throws -> URL {
        try await download(prepared, in: directory, estimatedBytes: estimatedBytes, submit: nil, onProgress: onProgress)
    }

    public func download(_ prepared: PreparedArchive, in directory: URL, estimatedBytes: Int64? = nil,
                         threads: Int = 1, submit: Submit?,
                         onProgress: (@Sendable (ArchiveByteProgress) -> Void)? = nil) async throws -> URL {
        guard maximumBytes > 0, AppPreferences.archiveDownloadThreadRange.contains(threads), directory.isFileURL,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.invalidInput }
        try Self.checkLink(prepared)
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(UUID().uuidString + ".zip")
        let partial = destination.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw AppError.storageFull }
        defer { try? FileManager.default.removeItem(at: partial) }

        let progress = ArchiveFileProgress(callback: onProgress)
        let url = prepared.downloadURL
        @Sendable func fetch(_ request: ArchiveFileRequest) async throws -> ArchiveFilePayload {
            let receiver = ArchiveFileReceiver(url: url, destination: partial, request: request,
                                               maximumBytes: maximumBytes, estimatedBytes: estimatedBytes,
                                               progress: progress, configuration: configuration)
            return try await receiver.run(submit: submit)
        }

        // A range probe that returns 200 already contains the whole file.
        let first = try await fetch(threads == 1 ? .whole : .probe)
        let size: Int64
        if let part = first.range {
            size = part.total
            let chunkSize = (size - 2) / Int64(threads) + 1
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<threads {
                    let start = 1 + Int64(index) * chunkSize
                    guard start < size else { break }
                    let range = ArchiveContentRange(bytes: start...(start + min(chunkSize, size - start) - 1), total: size)
                    group.addTask { _ = try await fetch(.part(range, etag: first.etag)) }
                }
                while try await group.next() != nil {}
            }
        } else {
            size = first.received
        }

        try Task.checkCancellation()
        let actual = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size >= 22, actual.map(Int64.init) == size else { throw ArchiveFileTransportError.invalidZip }
        let input = try FileHandle(forReadingFrom: partial)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw ArchiveFileTransportError.invalidZip
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// Revalidate the parsed capability at the transport boundary.
    public static func checkLink(_ prepared: PreparedArchive) throws {
        guard let target = URLComponents(url: prepared.downloadURL, resolvingAgainstBaseURL: false),
              let address = URLComponents(url: prepared.address.url, resolvingAgainstBaseURL: false),
              target.scheme == "https", target.host == address.host, target.port == address.port,
              target.user == nil, target.password == nil, target.fragment == nil,
              target.percentEncodedPath == address.percentEncodedPath,
              target.queryItems == [URLQueryItem(name: "start", value: "1")] else {
            throw AppError.accessDenied
        }
    }
}

private struct ArchiveContentRange: Equatable, Sendable {
    let bytes: ClosedRange<Int64>
    let total: Int64
    var length: Int64 { bytes.upperBound - bytes.lowerBound + 1 }

    static func parse(_ raw: String?) throws -> Self {
        let pieces = raw?.split(separator: " ") ?? []
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else {
            throw ArchiveFileTransportError.invalidResponse
        }
        let values = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard values.count == 2, let total = Int64(values[1]) else {
            throw ArchiveFileTransportError.invalidResponse
        }
        let bounds = values[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let low = Int64(bounds[0]), let high = Int64(bounds[1]),
              low >= 0, high >= low, high < total else { throw ArchiveFileTransportError.invalidResponse }
        return Self(bytes: low...high, total: total)
    }
}

private enum ArchiveFileRequest: Sendable {
    case whole, probe, part(ArchiveContentRange, etag: String?)

    var range: ClosedRange<Int64>? {
        switch self {
        case .whole: nil
        case .probe: 0...0
        case .part(let value, _): value.bytes
        }
    }
}

private struct ArchiveFilePayload: Sendable {
    let received: Int64
    let range: ArchiveContentRange?
    let etag: String?
}

private final class ArchiveFileProgress: Sendable {
    private let received = Mutex<Int64>(0)
    private let callback: (@Sendable (ArchiveByteProgress) -> Void)?

    init(callback: (@Sendable (ArchiveByteProgress) -> Void)?) { self.callback = callback }

    func report(delta: Int64, total: ArchiveTransferTotal) {
        guard let callback else { return }
        received.withLock { received in
            received += delta
            callback(ArchiveByteProgress(received: received, expected: total.bytes,
                                         isEstimated: total.isEstimated, delta: delta))
        }
    }
}

private final class ArchiveFileReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let destination: URL
    private let request: ArchiveFileRequest
    private let maximumBytes: UInt64
    private let estimatedBytes: Int64?
    private let progress: ArchiveFileProgress
    private let configuration: URLSessionConfiguration
    // Cancellation and gate submission can arrive on a different executor.
    private var continuation: CheckedContinuation<ArchiveFilePayload, any Error>?
    private var task: URLSessionDataTask?
    private var failure: (any Error)?
    // Initialized before resume and then owned by the serial session delegate.
    private var file: FileHandle?
    private var received: Int64 = 0
    private var total: ArchiveTransferTotal?
    private var contentRange: ArchiveContentRange?
    private var etag: String?

    init(url: URL, destination: URL, request: ArchiveFileRequest, maximumBytes: UInt64,
         estimatedBytes: Int64?, progress: ArchiveFileProgress, configuration: URLSessionConfiguration) {
        self.url = url
        self.destination = destination
        self.request = request
        self.maximumBytes = maximumBytes
        self.estimatedBytes = estimatedBytes
        self.progress = progress
        self.configuration = configuration
    }

    func run(submit: ArchiveFileTransport.Submit?) async throws -> ArchiveFilePayload {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let task = try lock.withLock {
                        if let failure { throw failure }
                        let output = try FileHandle(forWritingTo: destination)
                        do { try output.seek(toOffset: UInt64(request.range?.lowerBound ?? 0)) }
                        catch { try? output.close(); throw error }
                        file = output
                        self.continuation = continuation
                        let config = configuration.copy() as! URLSessionConfiguration
                        config.httpCookieStorage = nil
                        config.httpShouldSetCookies = false
                        config.urlCredentialStorage = nil
                        config.urlCache = nil
                        config.requestCachePolicy = .reloadIgnoringLocalCacheData
                        config.timeoutIntervalForRequest = 30
                        config.timeoutIntervalForResource = 30 * 60
                        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                        let task = session.dataTask(with: makeRequest())
                        self.task = task
                        return task
                    }
                    if let submit {
                        Task {
                            do { try await submit { self.start(task) } }
                            catch { self.fail(error) }
                        }
                    } else {
                        start(task)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.fail(CancellationError()) }
    }

    private func makeRequest() -> URLRequest {
        var result = URLRequest(url: url)
        result.httpMethod = "GET"
        result.httpShouldHandleCookies = false
        result.setValue("application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = request.range {
            result.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        if case .part(_, let etag) = request, let etag { result.setValue(etag, forHTTPHeaderField: "If-Range") }
        return result
    }

    private func start(_ task: URLSessionDataTask) {
        lock.withLock {
            guard failure == nil else { return }
            task.resume()
        }
    }

    private func fail(_ error: any Error) {
        let task = lock.withLock {
            if failure == nil { failure = error }
            return self.task
        }
        task?.cancel()
        // didCompleteWithError acknowledges the shutdown before the caller joins.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        fail(ArchiveFileTransportError.redirect(response.statusCode))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            let total = try inspect(response)
            self.total = total
            progress.report(delta: 0, total: total)
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    private func inspect(_ response: URLResponse) throws -> ArchiveTransferTotal {
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw ArchiveFileTransportError.invalidResponse
        }
        guard http.statusCode == 200 || http.statusCode == 206 && request.range != nil else {
            throw ArchiveFileTransportError.unexpectedStatus(http.statusCode)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard mime != "text/html", mime != "application/xhtml+xml" else {
            throw ArchiveFileTransportError.htmlResponse
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw ArchiveFileTransportError.invalidResponse
        }

        if http.statusCode == 206 {
            let part = try ArchiveContentRange.parse(http.value(forHTTPHeaderField: "Content-Range"))
            guard part.total >= 22, part.bytes == request.range,
                  response.expectedContentLength < 0 || response.expectedContentLength == part.length else {
                throw ArchiveFileTransportError.invalidResponse
            }
            guard UInt64(part.total) <= maximumBytes else { throw ArchiveFileTransportError.tooLarge }
            let receivedETag = http.value(forHTTPHeaderField: "ETag")
            if case .part(let required, let validator) = request {
                guard part == required, validator == nil || receivedETag == nil || receivedETag == validator else {
                    throw ArchiveFileTransportError.invalidResponse
                }
            } else {
                try checkCapacity(part.total)
            }
            contentRange = part
            if let receivedETag, receivedETag.first == "\"", receivedETag.last == "\"" { etag = receivedETag }
            return ArchiveTransferTotal(bytes: part.total, isEstimated: false)
        }

        if case .part = request { throw ArchiveFileTransportError.invalidResponse }
        guard http.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw ArchiveFileTransportError.invalidResponse
        }
        let total = try ArchiveTransferTotal.choose(responseLength: response.expectedContentLength,
            contentLength: http.value(forHTTPHeaderField: "Content-Length"),
            estimate: estimatedBytes, maximumBytes: maximumBytes)
        if let expected = total.bytes, !total.isEstimated { try checkCapacity(expected) }
        return total
    }

    private func checkCapacity(_ bytes: Int64) throws {
        let url = destination.deletingLastPathComponent()
        #if canImport(Darwin)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let capacity = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let capacity = values?.volumeAvailableCapacity.map(Int64.init)
        #endif
        if let capacity, capacity >= 0, capacity < bytes { throw AppError.storageFull }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let total, lock.withLock({ failure == nil }) else { return }
        let (count, overflow) = received.addingReportingOverflow(Int64(data.count))
        do {
            guard !overflow, UInt64(count) <= maximumBytes else { throw ArchiveFileTransportError.tooLarge }
            if let length = contentRange?.length ?? (total.isEstimated ? nil : total.bytes), count > length {
                throw ArchiveFileTransportError.invalidResponse
            }
            try file?.write(contentsOf: data)
            received = count
            progress.report(delta: Int64(data.count), total: total)
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiting, failure) = lock.withLock {
            let result = (continuation, self.failure)
            continuation = nil
            self.task = nil
            return result
        }
        session.finishTasksAndInvalidate()
        guard let waiting else { return }
        do {
            try file?.close()
            file = nil
            if let failure { throw failure }
            if let error {
                let code = (error as? URLError)?.errorCode ?? -1
                if code == NSURLErrorCancelled { throw CancellationError() }
                throw AppError.transport(code: code)
            }
            guard let total else { throw ArchiveFileTransportError.invalidResponse }
            if let length = contentRange?.length ?? (total.isEstimated ? nil : total.bytes), received != length {
                throw ArchiveFileTransportError.invalidResponse
            }
            waiting.resume(returning: ArchiveFilePayload(received: received, range: contentRange, etag: etag))
        } catch {
            waiting.resume(throwing: error)
        }
    }
}
