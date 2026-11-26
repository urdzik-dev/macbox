import Foundation
import Darwin

/// A flat, bounded exchange directory. Neither side follows links supplied by the other.
public final class Mailbox {
    private let directory: Int32
    public enum Failure: Error { case directory, invalidName, invalidFile, timeout, mismatchedReply }
    public init(path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.directory }
        directory = fd
    }
    deinit { close(directory) }
    private func checked(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 100,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { throw Failure.invalidName }
    }
    public func publish(_ data: Data, as name: String) throws {
        try checked(name)
        guard data.count <= ControlProtocol.maxMessageBytes + 4 else { throw ControlProtocol.ValidationError.messageTooLarge }
        let temporary = "tmp-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.invalidFile }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalidFile }
                offset += count
            }
        }
        guard renameat(directory, temporary, directory, name) == 0 else { throw Failure.invalidFile }
    }
    public func read(_ name: String) throws -> Data? {
        try checked(name)
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.invalidFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= ControlProtocol.maxMessageBytes + 4 else { throw Failure.invalidFile }
        var data = Data()
        // The size has been bounded above; reserve once for image responses.
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.invalidFile }
            if n == 0 { break }
            guard data.count + n <= ControlProtocol.maxMessageBytes + 4 else { throw Failure.invalidFile }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
    public func remove(_ name: String) throws { try checked(name); _ = unlinkat(directory, name, 0) }
    /// Exclusively owns one request while it is being consumed by an agent.
    /// A second agent skips the request; it must never execute the same action twice.
    public func withClaim(_ id: UUID, body: () throws -> Void) throws -> Bool {
        let name = "claim-" + id.uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 && errno == EEXIST { return false }
        guard fd >= 0 else { throw Failure.invalidFile }
        close(fd)
        defer { _ = unlinkat(directory, name, 0) }
        try body()
        return true
    }
    public func request(_ request: ControlProtocol.Request, timeout: TimeInterval = 15) throws -> ControlProtocol.Response {
        try request.validate()
        let suffix = request.id.uuidString
        let requestName = "request-" + suffix
        let responseName = "response-" + suffix
        defer { try? remove(requestName); try? remove(responseName) }
        try publish(ControlProtocol.encodeFrame(request), as: requestName)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try read(responseName) {
                let response = try ControlProtocol.decodeFrame(ControlProtocol.Response.self, from: data)
                guard response.id == request.id, response.version == ControlProtocol.version else { throw Failure.mismatchedReply }
                return response
            }
            usleep(20_000)
        }
        throw Failure.timeout
    }
}
