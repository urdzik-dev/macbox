import Foundation
import Darwin

public struct VMPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var diskImage: URL { root.appendingPathComponent("disk.img") }
    public var auxiliaryStorage: URL { root.appendingPathComponent("auxiliary.img") }
    public var hardwareModel: URL { root.appendingPathComponent("hardware-model.bin") }
    public var machineIdentifier: URL { root.appendingPathComponent("machine-id.bin") }
    public var lockFile: URL { root.appendingPathComponent("vm.lock") }
    public var exchange: URL { root.appendingPathComponent("exchange", isDirectory: true) }
    public var guestTools: URL { root.appendingPathComponent("guest-tools", isDirectory: true) }
    public var snapshotsDir: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
}

public struct StorageLayout: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let env = ProcessInfo.processInfo.environment["MACBOX_DATA_DIR"], !env.isEmpty {
            self.baseDirectory = URL(fileURLWithPath: NSString(string: env).expandingTildeInPath, isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".macbox", isDirectory: true)
        }
    }

    public var vmsDirectory: URL {
        baseDirectory.appendingPathComponent("vms", isDirectory: true)
    }

    public var imagesDirectory: URL {
        baseDirectory.appendingPathComponent("images", isDirectory: true)
    }

    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: vmsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    public static func validateVMName(_ name: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw MacBoxError.invalidVMName(name)
        }
    }

    public func vmPaths(named name: String) throws -> VMPaths {
        try Self.validateVMName(name)
        return VMPaths(root: vmsDirectory.appendingPathComponent(name, isDirectory: true))
    }

    public func listVMNames() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vmsDirectory.path) else {
            return []
        }
        let entries = try fm.contentsOfDirectory(
            at: vmsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func loadConfig(named name: String) throws -> VMConfig {
        let paths = try vmPaths(named: name)
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
            throw MacBoxError.vmNotFound(name)
        }
        let data = try Data(contentsOf: paths.configFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfig.self, from: data)
    }

    public func saveConfig(_ config: VMConfig) throws {
        let paths = try vmPaths(named: config.name)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: paths.configFile, options: .atomic)
    }

    /// Creates a sparse raw disk image on APFS using open + ftruncate (near-zero initial blocks).
    public static func createSparseDisk(at url: URL, sizeBytes: UInt64) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            let err = errno
            unlink(url.path)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
