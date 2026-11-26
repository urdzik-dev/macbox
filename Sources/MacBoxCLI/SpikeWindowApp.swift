import AppKit
import Foundation
import Virtualization
import MacBoxCore

@MainActor
final class SpikeWindowController: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private var config: VMConfig
    private let paths: VMPaths
    private let offlineOverride: Bool?
    private let recovery: Bool
    private let proxyExecutable: URL?
    private var userNetwork: UserNetwork?
    private var lock: VMLock?
    private var vm: VZVirtualMachine?
    private var window: NSWindow?
    private var vmView: VZVirtualMachineView?
    private var startOptions: VZMacOSVirtualMachineStartOptions?

    init(config: VMConfig, paths: VMPaths, offlineOverride: Bool?, recovery: Bool, proxyExecutable: URL? = nil) {
        self.config = config
        self.paths = paths
        self.offlineOverride = offlineOverride
        self.recovery = recovery
        self.proxyExecutable = proxyExecutable
    }

    func run() throws {
        try HostDiagnostics.ensureHostRequirements(layout: StorageLayout())
        self.lock = try VMLock.acquire(at: paths.lockFile, vmName: config.name)

        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        if !recovery, try FirstBootProvisioner.configure(options, config: config) {
            FileHandle.standardError.write(Data("Автоматичне налаштування macOS 27: обліковий запис macbox; пароль зберігається у Keychain хоста.\n".utf8))
        }
        self.startOptions = options

        if let proxyExecutable {
            guard !(offlineOverride ?? config.offline) else { throw MacBoxError.invalidConfiguration("VPN-мережа несумісна з offline-режимом.") }
            self.userNetwork = try UserNetwork(executable: proxyExecutable)
        }

        // Expose only the packaged guest helper, never the host's home directory.
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("MacBoxGuest.app")
        let destination = paths.guestTools.appendingPathComponent("MacBoxGuest.app")
        try FileManager.default.createDirectory(at: paths.guestTools, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: helper.path) {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: helper, to: destination)
        } else {
            FileHandle.standardError.write(Data("Гостьовий застосунок відсутній; запустіть scripts/build-and-sign.sh.\n".utf8))
        }

        let vzConfig = try VirtualMachineBuilder.buildConfiguration(
            config: config,
            paths: paths,
            offlineOverride: offlineOverride,
            userNetwork: userNetwork?.handle
        )

        let machine = VZVirtualMachine(configuration: vzConfig)
        machine.delegate = self
        self.vm = machine

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let vm else { return }

        let scale: CGFloat = config.display.hiDPI ? 2.0 : 1.0
        let contentWidth = CGFloat(config.display.widthPixels) / scale
        let contentHeight = CGFloat(config.display.heightPixels) / scale

        let rect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "MacBox — \(config.name) (\(config.display.widthPixels)x\(config.display.heightPixels))"
        win.delegate = self
        win.center()

        let view = VZVirtualMachineView(frame: rect)
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        self.window = win
        self.vmView = view

        NSApp.activate(ignoringOtherApps: true)

        guard let options = startOptions else { cleanupAndTerminate(exitCode: 1); return }

        FileHandle.standardError.write(Data("Запуск VM '\(config.name)'...\n".utf8))
        vm.start(options: options) { [weak self] error in
          Task { @MainActor in
            if let error {
                FileHandle.standardError.write(Data("Помилка запуску VM: \(error.localizedDescription)\n".utf8))
                self?.cleanupAndTerminate(exitCode: 1)
            } else {
                FileHandle.standardError.write(Data("VM '\(self?.config.name ?? "")' запущена.\n".utf8))
                guard let self else { return }
                if self.config.firstBootPending == true && !self.recovery {
                    self.config.firstBootPending = false
                    let base = self.paths.root.deletingLastPathComponent().deletingLastPathComponent()
                    do { try StorageLayout(baseDirectory: base).saveConfig(self.config) }
                    catch { FileHandle.standardError.write(Data("Не вдалося зберегти стан першого запуску: \(error.localizedDescription)\n".utf8)) }
                }
                let name = self.config.name
                let base = self.paths.root.deletingLastPathComponent().deletingLastPathComponent()
                Task.detached {
                    var lastState: GuestReadiness.State?
                    while !Task.isCancelled {
                        let report = try? GuestReadiness.check(vm: name, layout: StorageLayout(baseDirectory: base))
                        if let report, report.state != lastState {
                            lastState = report.state
                            FileHandle.standardError.write(Data("MacBox: \(report.message)\n".utf8))
                            if report.isReady { break }
                        }
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
          }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let vm, vm.state == .running || vm.state == .paused else {
            cleanupAndTerminate(exitCode: 0)
            return
        }
        FileHandle.standardError.write(Data("Зупинка VM '\(config.name)'...\n".utf8))
        do {
            guard vm.canRequestStop else {
                FileHandle.standardError.write(Data("VM не може прийняти запит на завершення; процес залишається активним.\n".utf8))
                return
            }
            try vm.requestStop()
            // Keep the process and lock alive until the guest confirms shutdown.
            // A fixed timeout followed by force-stop could destroy unsaved work.
        } catch {
            FileHandle.standardError.write(Data("Не вдалося штатно завершити VM: \(error.localizedDescription)\n".utf8))
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            FileHandle.standardError.write(Data("Гостьова ОС завершила роботу.\n".utf8))
            self.cleanupAndTerminate(exitCode: 0)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            FileHandle.standardError.write(Data("VM зупинилась із помилкою: \(error.localizedDescription)\n".utf8))
            self.cleanupAndTerminate(exitCode: 1)
        }
    }

    private func cleanupAndTerminate(exitCode: Int32) {
        lock?.release()
        lock = nil
        NSApp.terminate(nil)
        exit(exitCode)
    }
}
