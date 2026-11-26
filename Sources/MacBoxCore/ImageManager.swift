import Foundation
import Virtualization
import CryptoKit
import MacBoxProtocol

public struct RestoreImageMetadata: Codable, Sendable {
    public let url: String
    public let buildVersion: String
    public let operatingSystemVersion: String
    public let minCPUs: Int
    public let minMemoryGiB: Double

    public init(
        url: String,
        buildVersion: String,
        operatingSystemVersion: String,
        minCPUs: Int,
        minMemoryGiB: Double
    ) {
        self.url = url
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.minCPUs = minCPUs
        self.minMemoryGiB = minMemoryGiB
    }
}

public enum ImageManager {
    struct ResumeRecord: Codable {
        let source: String
        let data: Data
    }

    static func resumeKey(for destination: URL) -> String {
        let digest = SHA256.hash(data: Data(destination.standardizedFileURL.path.utf8))
        return "resume-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func loadResume(from box: Mailbox, key: String, source: URL) -> Data? {
        guard let bytes = try? box.read(key), bytes.count <= 8 * 1024 * 1024,
              let record = try? JSONDecoder().decode(ResumeRecord.self, from: bytes),
              record.source == source.absoluteString, !record.data.isEmpty else { return nil }
        return record.data
    }
    static func validateDownloadResponse(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "невідомий"
            throw MacBoxError.restoreImageUnavailable("Сервер повернув HTTP \(status); образ не збережено.")
        }
    }
    public static func fetchLatestSupportedMetadata() async throws -> (image: VZMacOSRestoreImage, metadata: RestoreImageMetadata) {
        let image: VZMacOSRestoreImage
        do {
            image = try await VZMacOSRestoreImage.latestSupported
        } catch {
            throw MacBoxError.restoreImageUnavailable(error.localizedDescription)
        }

        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw MacBoxError.restoreImageUnavailable("Немає підтримуваної конфігурації обладнання для цього IPSW.")
        }

        let ver = image.operatingSystemVersion
        let verString = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
        let metadata = RestoreImageMetadata(
            url: image.url.absoluteString,
            buildVersion: image.buildVersion,
            operatingSystemVersion: verString,
            minCPUs: requirements.minimumSupportedCPUCount,
            minMemoryGiB: Double(requirements.minimumSupportedMemorySize) / (1024.0 * 1024.0 * 1024.0)
        )
        return (image, metadata)
    }

    public static func loadLocalImage(at url: URL) async throws -> (image: VZMacOSRestoreImage, metadata: RestoreImageMetadata) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacBoxError.missingFile(url.path)
        }
        let image: VZMacOSRestoreImage
        do {
            image = try await VZMacOSRestoreImage.image(from: url)
        } catch {
            throw MacBoxError.restoreImageUnavailable(error.localizedDescription)
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw MacBoxError.restoreImageUnavailable("Локальний IPSW не підтримується поточним хостом.")
        }
        let ver = image.operatingSystemVersion
        let verString = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
        let metadata = RestoreImageMetadata(
            url: url.path,
            buildVersion: image.buildVersion,
            operatingSystemVersion: verString,
            minCPUs: requirements.minimumSupportedCPUCount,
            minMemoryGiB: Double(requirements.minimumSupportedMemorySize) / (1024.0 * 1024.0 * 1024.0)
        )
        return (image, metadata)
    }

    public static func downloadRestoreImage(
        from remoteURL: URL,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: destinationURL.path) else {
            throw MacBoxError.invalidConfiguration("Файл образу вже існує: \(destinationURL.path). Існуючий файл не перезаписано.")
        }
        let box = try Mailbox(path: destinationURL.deletingLastPathComponent().path)
        let key = resumeKey(for: destinationURL)
        let previous = loadResume(from: box, key: key, source: remoteURL)
        let delegate = DownloadProgressDelegate(onProgress: onProgress, box: box, key: key, source: remoteURL, wasResumed: previous != nil)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task = previous.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: remoteURL)
            task.resume()
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard !fm.fileExists(atPath: destinationURL.path) else {
            throw MacBoxError.invalidConfiguration("Файл образу вже існує: \(destinationURL.path). Існуючий файл не перезаписано.")
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
        try? box.remove(key)
        return destinationURL
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var lastReportedPercent = -1
    private let box: Mailbox
    private let key: String
    private let source: URL
    private let wasResumed: Bool

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void, box: Mailbox, key: String, source: URL, wasResumed: Bool) {
        self.onProgress = onProgress
        self.box = box
        self.key = key
        self.source = source
        self.wasResumed = wasResumed
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100.0)
            if percent != lastReportedPercent {
                lastReportedPercent = percent
                onProgress(totalBytesWritten, totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try ImageManager.validateDownloadResponse(downloadTask.response) }
        catch {
            if wasResumed { try? box.remove(key) }
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        // Move out of URLSession's ephemeral temp location immediately before returning
        let stableTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbox-ipsw-\(UUID().uuidString).ipsw")
        do {
            try FileManager.default.moveItem(at: location, to: stableTemp)
            continuation?.resume(returning: stableTemp)
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let cont = continuation {
            let saved = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let saved, !saved.isEmpty, saved.count <= 5 * 1024 * 1024,
               let encoded = try? JSONEncoder().encode(ImageManager.ResumeRecord(source: source.absoluteString, data: saved)) {
                try? box.publish(encoded, as: key)
            } else if wasResumed && !Self.isTransientNetworkFailure(error) {
                // An invalid or unusable resume record should not trap every subsequent attempt.
                try? box.remove(key)
            }
            cont.resume(throwing: error)
            continuation = nil
        }
    }

    private static func isTransientNetworkFailure(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed].contains(error.code)
    }
}
