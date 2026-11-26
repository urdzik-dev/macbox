import Foundation
import Darwin
import Security

/// Optional userspace Ethernet bridge. The caller supplies a trusted gvproxy executable.
public final class UserNetwork {
    public let handle: FileHandle
    private let process: Process
    private let directory: URL

    public init(executable: URL) throws {
        guard executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MacBoxError.invalidConfiguration("Вкажіть абсолютний шлях до виконуваного gvproxy.")
        }
        let directory = URL(fileURLWithPath: "/tmp/mbnet-" + UUID().uuidString.prefix(12), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let remote = directory.appendingPathComponent("proxy.sock").path
        let local = directory.appendingPathComponent("vm.sock").path
        let tokenPath = directory.appendingPathComponent("api-token").path
        let process = Process()
        process.executableURL = executable
        do {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw MacBoxError.invalidConfiguration("Не вдалося створити токен мережевого сервісу.")
            }
            let token = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            guard FileManager.default.createFile(atPath: tokenPath, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw MacBoxError.invalidConfiguration("Не вдалося створити файл мережевого токена.")
            }
            // Disable gvproxy's default localhost SSH forwarding; the VM did not request it.
            process.arguments = ["--listen-vfkit", "unixgram://" + remote, "--api-token-file", tokenPath, "--ssh-port", "-1"]
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !FileManager.default.fileExists(atPath: remote) {
                guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw MacBoxError.invalidConfiguration("gvproxy не створив мережевий сокет.")
                }
                usleep(50_000)
            }
            let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            do {
                try Self.attach(fd: fd, local: local, remote: remote)
                let magic = Array("VFKT".utf8)
                guard magic.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == magic.count else { throw POSIXError(.EIO) }
            } catch { close(fd); throw error }
            self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.process = process
            self.directory = directory
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw MacBoxError.invalidConfiguration("Шлях мережевого сокета задовгий.") }
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }

    private static func attach(fd: Int32, local: String, remote: String) throws {
        var localAddress = try address(local)
        var remoteAddress = try address(remote)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &localAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let connected = withUnsafePointer(to: &remoteAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit {
        try? handle.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
