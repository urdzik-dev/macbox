import Foundation
import Virtualization

public enum VirtualMachineBuilder {
    /// Builds a `VZVirtualMachineConfiguration` for an existing macOS VM.
    /// Enforces isolation by default: no shared clipboard, no USB passthrough, no host home sharing.
    public static func buildConfiguration(
        config: VMConfig,
        paths: VMPaths,
        offlineOverride: Bool? = nil,
        userNetwork: FileHandle? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        for required in [paths.diskImage, paths.auxiliaryStorage, paths.hardwareModel, paths.machineIdentifier] {
            guard fm.fileExists(atPath: required.path) else {
                throw MacBoxError.missingFile(required.path)
            }
        }

        let hardwareModelData = try Data(contentsOf: paths.hardwareModel)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw MacBoxError.invalidConfiguration("Не вдалося декодувати hardware-model.bin")
        }
        guard hardwareModel.isSupported else {
            throw MacBoxError.invalidConfiguration("Цей hardware model не підтримується поточним хостом.")
        }

        let machineIDData = try Data(contentsOf: paths.machineIdentifier)
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIDData) else {
            throw MacBoxError.invalidConfiguration("Не вдалося декодувати machine-id.bin")
        }

        let auxStorage = VZMacAuxiliaryStorage(url: paths.auxiliaryStorage)

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxStorage

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.platform = platform
        vzConfig.bootLoader = VZMacOSBootLoader()
        vzConfig.cpuCount = clampCPUCount(config.cpuCount)
        vzConfig.memorySize = clampMemoryBytes(config.memoryBytes)

        // Graphics
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.widthPixels,
                heightInPixels: config.display.heightPixels,
                pixelsPerInch: config.display.pixelsPerInch
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        // Storage (sparse raw disk)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: paths.diskImage,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        vzConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Input devices (used for interactive window / Setup Assistant)
        vzConfig.keyboards = [VZMacKeyboardConfiguration()]
        vzConfig.pointingDevices = [VZMacTrackpadConfiguration()]

        // Entropy
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Network (NAT unless offline)
        let isOffline = offlineOverride ?? config.offline
        if !isOffline {
            let network = VZVirtioNetworkDeviceConfiguration()
            if let userNetwork { network.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: userNetwork) }
            else { network.attachment = VZNATNetworkDeviceAttachment() }
            vzConfig.networkDevices = [network]
        }

        try fm.createDirectory(at: paths.exchange, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: paths.guestTools, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = VZMultipleDirectoryShare(directories: [
            "control": VZSharedDirectory(url: paths.exchange, readOnly: false),
            "tools": VZSharedDirectory(url: paths.guestTools, readOnly: true)
        ])
        vzConfig.directorySharingDevices = [fs]
        try vzConfig.validate()
        return vzConfig
    }

    public static func clampCPUCount(_ requested: Int) -> Int {
        let minAllowed = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return min(max(requested, minAllowed), maxAllowed)
    }

    public static func clampMemoryBytes(_ requested: UInt64) -> UInt64 {
        let minAllowed = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(requested, minAllowed), maxAllowed)
    }
}
