import Foundation
import Testing
import MacBoxProtocol
import Virtualization
@testable import MacBoxCore

@Suite("MacBoxCore Phase 1 Tests")
struct MacBoxCoreTests {
    @Test("VM name validation rejects path traversal and accepts valid names")
    func validateVMName() throws {
        try StorageLayout.validateVMName("agent-1")
        try StorageLayout.validateVMName("dev_box_01")

        #expect(throws: MacBoxError.self) {
            try StorageLayout.validateVMName("../escape")
        }
        #expect(throws: MacBoxError.self) {
            try StorageLayout.validateVMName("")
        }
        #expect(throws: MacBoxError.self) {
            try StorageLayout.validateVMName("-leading-dash")
        }
        #expect(throws: MacBoxError.self) {
            try StorageLayout.validateVMName("has space")
        }
    }

    @Test("VMConfig round-trip JSON serialization preserves all fields")
    func vmConfigRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbox-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = StorageLayout(baseDirectory: tempDir)
        try layout.ensureBaseDirectories()

        let original = VMConfig(
            name: "sandbox1",
            cpuCount: 4,
            memoryGiB: 8,
            diskGiB: 64,
            display: .defaultHiDPI,
            offline: true,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            guestOSBuild: "25F84",
            installed: true
        )
        try layout.saveConfig(original)
        let loaded = try layout.loadConfig(named: "sandbox1")
        #expect(loaded == original)
        #expect(try layout.listVMNames() == ["sandbox1"])
    }

    @Test("VMLock prevents double acquisition and releases cleanly")
    func vmLockMutualExclusion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbox-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lockURL = tempDir.appendingPathComponent("vm.lock")
        #expect(!VMLock.isLocked(at: lockURL))

        let lock1 = try VMLock.acquire(at: lockURL, vmName: "testvm")
        #expect(VMLock.isLocked(at: lockURL))

        #expect(throws: MacBoxError.self) {
            _ = try VMLock.acquire(at: lockURL, vmName: "testvm")
        }

        lock1.release()
        #expect(!VMLock.isLocked(at: lockURL))

        let lock2 = try VMLock.acquire(at: lockURL, vmName: "testvm")
        lock2.release()
    }

    @Test("Sparse disk creation creates logical 64 GiB file with minimal allocated blocks")
    func sparseDiskCreation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macbox-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("disk.img")
        let sizeBytes: UInt64 = 64 * 1024 * 1024 * 1024
        try StorageLayout.createSparseDisk(at: diskURL, sizeBytes: sizeBytes)

        let values = try diskURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        #expect(values.fileSize == Int(sizeBytes))
        // Sparse file should allocate almost zero bytes initially (< 1 MiB)
        #expect((values.fileAllocatedSize ?? 0) < 1_048_576)
    }

    @Test("Error messages include actionable recovery hints")
    func errorHintsPresent() {
        #expect(MacBoxError.missingVirtualizationEntitlement.recoveryHint != nil)
        #expect(MacBoxError.unsupportedArchitecture("x86_64").recoveryHint != nil)
        #expect(MacBoxError.unsupportedMacOSVersion("13.6").recoveryHint != nil)
        #expect(MacBoxError.insufficientDiskSpace(availableGiB: 10, requiredGiB: 50).recoveryHint != nil)
    }
}

@Suite("Guest readiness") struct GuestReadinessTests {
    @Test func stoppedMachineIsNotReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = StorageLayout(baseDirectory: root)
        try layout.ensureBaseDirectories()
        try layout.saveConfig(VMConfig(name: "test", installed: true))
        let report = try GuestReadiness.check(vm: "test", layout: layout, timeout: 0.1)
        #expect(report.state == .vmStopped)
        #expect(!report.isReady)
    }
    @Test func missingPermissionsAreReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = StorageLayout(baseDirectory: root)
        try layout.ensureBaseDirectories()
        try layout.saveConfig(VMConfig(name: "test", installed: true))
        let paths = try layout.vmPaths(named: "test")
        try FileManager.default.createDirectory(at: paths.exchange, withIntermediateDirectories: true)
        let lock = try VMLock.acquire(at: paths.lockFile, vmName: "test")
        defer { lock.release() }
        let worker = Task.detached { () throws -> Void in
            let box = try Mailbox(path: paths.exchange.path)
            for _ in 0..<200 {
                let names = try FileManager.default.contentsOfDirectory(atPath: paths.exchange.path)
                if let name = names.first(where: { $0.hasPrefix("request-") }), let data = try box.read(name) {
                    let request = try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: data)
                    let response = ControlProtocol.Response(id: request.id, result: .status(screenRecording: true, accessibility: false))
                    try box.publish(ControlProtocol.encodeFrame(response), as: "response-" + request.id.uuidString)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Mailbox.Failure.timeout
        }
        let report = try GuestReadiness.check(vm: "test", layout: layout, timeout: 2)
        try await worker.value
        #expect(report.state == .permissionsRequired)
        #expect(report.screenRecording == true)
        #expect(report.accessibility == false)
    }
}

@Suite("First boot provisioning") struct FirstBootProvisioningTests {
    @Test func unsupportedHostDoesNotStartNewGuest() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else { return }
        var config = VMConfig(name: "test")
        config.firstBootPending = true
        config.guestOSVersion = "27.0"
        config.provisioningID = UUID()
        #expect(throws: FirstBootProvisioner.Failure.self) {
            try FirstBootProvisioner.configure(VZMacOSVirtualMachineStartOptions(), config: config)
        }
    }
    @Test func oldConfigRemainsReadable() throws {
        let encoded = try JSONEncoder().encode(VMConfig(name: "legacy"))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "guestOSVersion")
        object.removeValue(forKey: "firstBootPending")
        object.removeValue(forKey: "provisioningID")
        let decoded = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.name == "legacy")
        #expect(decoded.firstBootPending == nil)
        #expect(!FirstBootProvisioner.shouldProvision(decoded, hostMajor: 27))
    }
    @Test func requiresFreshGuestAndCompatibleVersions() {
        var config = VMConfig(name: "vm")
        config.guestOSVersion = "27.0.0"
        config.firstBootPending = true
        config.provisioningID = UUID()
        #expect(FirstBootProvisioner.shouldProvision(config, hostMajor: 27))
        #expect(!FirstBootProvisioner.shouldProvision(config, hostMajor: 26))
        config.guestOSVersion = "26.5.0"
        #expect(!FirstBootProvisioner.shouldProvision(config, hostMajor: 27))
        config.guestOSVersion = "27.0"
        config.firstBootPending = false
        #expect(!FirstBootProvisioner.shouldProvision(config, hostMajor: 27))
        config.firstBootPending = nil
        #expect(!FirstBootProvisioner.shouldProvision(config, hostMajor: 27))
    }
}

@Suite("Restore download response") struct RestoreDownloadTests {
    @Test func existingImageIsNeverOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("image.ipsw")
        let existing = Data("original".utf8)
        try existing.write(to: destination)
        do {
            _ = try await ImageManager.downloadRestoreImage(from: URL(string: "https://example.invalid/image")!, to: destination) { _, _ in }
            Issue.record("Expected an existing-image error")
        } catch { }
        #expect(try Data(contentsOf: destination) == existing)
    }
    @Test func resumeStateIsBoundToItsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = try Mailbox(path: root.path)
        let source = try #require(URL(string: "https://example.invalid/image"))
        let other = try #require(URL(string: "https://example.invalid/other"))
        let key = ImageManager.resumeKey(for: root.appendingPathComponent("image.ipsw"))
        let state = ImageManager.ResumeRecord(source: source.absoluteString, data: Data([1, 2, 3]))
        try box.publish(JSONEncoder().encode(state), as: key)
        #expect(ImageManager.loadResume(from: box, key: key, source: source) == Data([1, 2, 3]))
        #expect(ImageManager.loadResume(from: box, key: key, source: other) == nil)
    }
    @Test func onlySuccessfulHTTPResponsesAreAccepted() throws {
        let url = try #require(URL(string: "https://example.invalid/restore.ipsw"))
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let error = try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
        try ImageManager.validateDownloadResponse(ok)
        #expect(throws: MacBoxError.self) { try ImageManager.validateDownloadResponse(error) }
        #expect(throws: MacBoxError.self) { try ImageManager.validateDownloadResponse(nil) }
    }
}

@Suite("Guest update identity") struct AgentIdentityTests {
    @Test func rejectsDifferentSigningRequirement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trusted = root.appendingPathComponent("trusted")
        let identical = root.appendingPathComponent("identical")
        let other = root.appendingPathComponent("other")
        let rebuilt = root.appendingPathComponent("rebuilt")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: trusted)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: other)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: rebuilt)
        func sign(_ file: URL, _ identifier: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", "--identifier", identifier, file.path]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try sign(trusted, "ua.macbox.agent")
        try sign(other, "ua.macbox.untrusted")
        try sign(rebuilt, "ua.macbox.agent")
        try FileManager.default.copyItem(at: trusted, to: identical)
        try AgentIdentity.validateUpdate(installed: trusted, candidate: identical)
        #expect(throws: AgentIdentity.Failure.self) { try AgentIdentity.validateUpdate(installed: trusted, candidate: other) }
        #expect(throws: AgentIdentity.Failure.self) { try AgentIdentity.validateUpdate(installed: trusted, candidate: rebuilt) }
        let destination = root.appendingPathComponent("installed")
        #expect(try AgentInstaller.installIfAbsent(source: trusted, destination: destination))
        try AgentIdentity.validateUpdate(installed: trusted, candidate: destination)
        #expect(try !AgentInstaller.installIfAbsent(source: other, destination: destination))
        try AgentIdentity.validateUpdate(installed: trusted, candidate: destination)
    }
}

@Suite("Agent update safety") struct AgentUpdateSafetyTests {
    @Test func rollbackRestoresPreviousBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let current = root.appendingPathComponent("current.app")
        let backup = root.appendingPathComponent("backup.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("version"))
        try Data("old".utf8).write(to: backup.appendingPathComponent("version"))
        try AgentInstaller.rollback(destination: current, backup: backup)
        #expect(try Data(contentsOf: current.appendingPathComponent("version")) == Data("old".utf8))
        #expect(try Data(contentsOf: backup.appendingPathComponent("version")) == Data("new".utf8))
    }
    @Test func untrustedNewerVersionCannotReplaceInstalledApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed.app")
        let candidate = root.appendingPathComponent("candidate.app")
        func create(_ url: URL, version: String, identifier: String) throws {
            let contents = url.appendingPathComponent("Contents")
            let bin = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin.appendingPathComponent("app"))
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "app", "CFBundleVersion": version, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", url.path]; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        }
        try create(installed, version: "1", identifier: "ua.macbox.trusted")
        try create(candidate, version: "2", identifier: "ua.macbox.other")
        #expect(throws: AgentIdentity.Failure.self) { try AgentInstaller.upgradeIfNewer(source: candidate, destination: installed) }
        let info = try #require(Bundle(url: installed)?.infoDictionary)
        #expect(info["CFBundleVersion"] as? String == "1")
        try AgentIdentity.validateUpdate(installed: installed, candidate: installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
}

@Suite("User network transport") struct UserNetworkTests {
    @Test func optionalRealProxyStarts() throws {
        guard let path = ProcessInfo.processInfo.environment["MACBOX_GVPROXY_TEST"] else { return }
        let network = try UserNetwork(executable: URL(fileURLWithPath: path))
        #expect(network.handle.fileDescriptor >= 0)
    }
    @Test func startsProxyAndExchangesDatagram() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proxy = root.appendingPathComponent("fake-proxy")
        let script = #"""
#!/usr/bin/python3
import socket, sys
path = sys.argv[2].removeprefix('unixgram://')
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind(path)
data, address = s.recvfrom(2048)
if data == b'VFKT':
    s.sendto(b'OK', address)
s.recvfrom(2048)
"""#
        try Data(script.utf8).write(to: proxy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: proxy.path)
        let network = try UserNetwork(executable: proxy)
        #expect(network.handle.availableData == Data("OK".utf8))
    }
    @Test func rejectsMissingProxy() {
        #expect(throws: MacBoxError.self) { try UserNetwork(executable: URL(fileURLWithPath: "/no/such/gvproxy")) }
    }
}
