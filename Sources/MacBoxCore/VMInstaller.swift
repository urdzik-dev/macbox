import Foundation
import Virtualization
import Darwin

public enum VMInstaller {
    public struct CreateOptions: Sendable {
        public let name: String
        public let ipswPath: URL?
        public let cpuCount: Int
        public let memoryGiB: Int
        public let diskGiB: Int
        public let display: VMDisplayConfig
        public let offline: Bool

        public init(
            name: String,
            ipswPath: URL? = nil,
            cpuCount: Int = 4,
            memoryGiB: Int = 8,
            diskGiB: Int = 64,
            display: VMDisplayConfig = .defaultHiDPI,
            offline: Bool = false
        ) {
            self.name = name
            self.ipswPath = ipswPath
            self.cpuCount = cpuCount
            self.memoryGiB = memoryGiB
            self.diskGiB = diskGiB
            self.display = display
            self.offline = offline
        }
    }

    /// Creates VM bundle, sparse disk, hardware model, auxiliary storage, and installs macOS from IPSW.
    @MainActor
    public static func createAndInstall(
        options: CreateOptions,
        layout: StorageLayout,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> VMConfig {
        try HostDiagnostics.ensureHostRequirements(layout: layout)
        try layout.ensureBaseDirectories()

        let paths = try layout.vmPaths(named: options.name)
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.root.path) {
            throw MacBoxError.vmAlreadyExists(options.name)
        }

        // Resolve IPSW (local or download from Apple)
        let localIPSW: URL
        let restoreImage: VZMacOSRestoreImage
        let metadata: RestoreImageMetadata

        if let providedPath = options.ipswPath {
            onStatus("Перевірка локального IPSW: \(providedPath.path)")
            (restoreImage, metadata) = try await ImageManager.loadLocalImage(at: providedPath)
            localIPSW = providedPath
        } else {
            onStatus("Отримання метаданих останнього підтримуваного macOS IPSW від Apple...")
            let (remoteImage, remoteMeta) = try await ImageManager.fetchLatestSupportedMetadata()
            let cachedURL = layout.imagesDirectory.appendingPathComponent("macOS-\(remoteMeta.buildVersion).ipsw")
            if fm.fileExists(atPath: cachedURL.path) {
                onStatus("Використано кешований IPSW: \(cachedURL.path)")
                localIPSW = cachedURL
            } else {
                onStatus("Завантаження macOS \(remoteMeta.operatingSystemVersion) (\(remoteMeta.buildVersion))...")
                localIPSW = try await ImageManager.downloadRestoreImage(
                    from: remoteImage.url,
                    to: cachedURL
                ) { written, total in
                    let pct = Int((Double(written) / Double(total)) * 100.0)
                    let writtenGB = Double(written) / 1_073_741_824.0
                    let totalGB = Double(total) / 1_073_741_824.0
                    onStatus(String(format: "Завантаження IPSW: %d%% (%.2f / %.2f GiB)", pct, writtenGB, totalGB))
                }
            }
            (restoreImage, metadata) = try await ImageManager.loadLocalImage(at: localIPSW)
        }

        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacBoxError.restoreImageUnavailable("Немає підтримуваної конфігурації для цього IPSW.")
        }

        let effectiveCPUs = max(options.cpuCount, requirements.minimumSupportedCPUCount)
        let minMemGiB = Int(ceil(Double(requirements.minimumSupportedMemorySize) / (1024.0 * 1024.0 * 1024.0)))
        let effectiveMemGiB = max(options.memoryGiB, minMemGiB)

        // Create bundle directory; roll back on failure
        guard mkdir(paths.root.path, 0o700) == 0 else {
            if errno == EEXIST { throw MacBoxError.vmAlreadyExists(options.name) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            onStatus("Створення sparse-диска (\(options.diskGiB) GiB)...")
            try StorageLayout.createSparseDisk(at: paths.diskImage, sizeBytes: UInt64(options.diskGiB) * 1024 * 1024 * 1024)

            let hwModel = requirements.hardwareModel
            try hwModel.dataRepresentation.write(to: paths.hardwareModel, options: .atomic)

            let machineID = VZMacMachineIdentifier()
            try machineID.dataRepresentation.write(to: paths.machineIdentifier, options: .atomic)

            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: paths.auxiliaryStorage,
                hardwareModel: hwModel,
                options: [.allowOverwrite]
            )

            var config = VMConfig(
                name: options.name,
                cpuCount: effectiveCPUs,
                memoryGiB: effectiveMemGiB,
                diskGiB: options.diskGiB,
                display: options.display,
                offline: options.offline,
                guestOSBuild: metadata.buildVersion,
                installed: false
            )
            config.guestOSVersion = metadata.operatingSystemVersion
            config.firstBootPending = true
            config.provisioningID = UUID()
            try layout.saveConfig(config)

            let vzConfig = try VirtualMachineBuilder.buildConfiguration(config: config, paths: paths)
            let vm = VZVirtualMachine(configuration: vzConfig)

            onStatus("Встановлення macOS \(metadata.operatingSystemVersion) (\(metadata.buildVersion)) у VM '\(options.name)'...")
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localIPSW)

            let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let pct = Int(progress.fractionCompleted * 100.0)
                onStatus("Встановлення macOS: \(pct)%")
            }
            defer { observation.invalidate() }

            try await installer.install()

            config.installed = true
            try layout.saveConfig(config)
            onStatus("Встановлення завершено успішно! Запустіть: macbox start \(options.name) --window")
            return config
        } catch {
            try? fm.removeItem(at: paths.root)
            if let macBoxErr = error as? MacBoxError {
                throw macBoxErr
            }
            throw MacBoxError.installationFailed(error.localizedDescription)
        }
    }
}
