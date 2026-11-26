import Foundation
import Darwin

/// Advisory process lock using POSIX `flock(2)` to prevent running the same VM twice.
public final class VMLock: @unchecked Sendable {
    private let fd: Int32
    public let path: URL
    private var released = false

    private init(fd: Int32, path: URL) {
        self.fd = fd
        self.path = path
    }

    public static func acquire(at url: URL, vmName: String) throws -> VMLock {
        let fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                throw MacBoxError.vmAlreadyRunning(vmName)
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        // Record PID for diagnostic visibility
        let pidString = "\(getpid())\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = pidString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        return VMLock(fd: fd, path: url)
    }

    public static func isLocked(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return errno == EWOULDBLOCK
        }
        flock(fd, LOCK_UN)
        return false
    }

    public func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit {
        release()
    }
}
