import Foundation

public struct VMDisplayConfig: Codable, Sendable, Equatable {
    public var widthPixels: Int
    public var heightPixels: Int
    public var pixelsPerInch: Int
    public var hiDPI: Bool

    public static let defaultHiDPI = VMDisplayConfig(
        widthPixels: 2560,
        heightPixels: 1600,
        pixelsPerInch: 220,
        hiDPI: true
    )

    public static let defaultStandard = VMDisplayConfig(
        widthPixels: 1280,
        heightPixels: 800,
        pixelsPerInch: 110,
        hiDPI: false
    )

    public init(widthPixels: Int, heightPixels: Int, pixelsPerInch: Int, hiDPI: Bool) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.pixelsPerInch = pixelsPerInch
        self.hiDPI = hiDPI
    }
}

public struct VMConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var name: String
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var display: VMDisplayConfig
    public var offline: Bool
    public var createdAt: Date
    public var guestOSBuild: String?
    public var installed: Bool
    /// Nil on older machines; only fresh installations can use first-boot provisioning.
    public var guestOSVersion: String?
    public var firstBootPending: Bool?
    public var provisioningID: UUID?

    public init(
        name: String,
        cpuCount: Int = 4,
        memoryGiB: Int = 8,
        diskGiB: Int = 64,
        display: VMDisplayConfig = .defaultHiDPI,
        offline: Bool = false,
        createdAt: Date = Date(),
        guestOSBuild: String? = nil,
        installed: Bool = false
    ) {
        self.schemaVersion = 1
        self.name = name
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.display = display
        self.offline = offline
        self.createdAt = createdAt
        self.guestOSBuild = guestOSBuild
        self.installed = installed
    }

    public var memoryBytes: UInt64 {
        UInt64(memoryGiB) * 1024 * 1024 * 1024
    }

    public var diskBytes: UInt64 {
        UInt64(diskGiB) * 1024 * 1024 * 1024
    }
}
