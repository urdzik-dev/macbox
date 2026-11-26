import Foundation
import MacBoxCore

@main
struct MacBoxCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let (globalDataDir, jsonOutput, remaining) = extractGlobalFlags(args)
        let layout = StorageLayout(baseDirectory: globalDataDir.map { URL(fileURLWithPath: $0, isDirectory: true) })

        if remaining.first == "mcp" {
            MCPServer.run(layout: layout)
            return
        }

        if remaining.first == "up" {
            do {
                try MainActor.assumeIsolated {
                    try handleUpSync(args: Array(remaining.dropFirst()), layout: layout)
                }
            } catch let err as MacBoxError {
                printError(err.localizedDescription, hint: err.recoveryHint)
                exit(1)
            } catch {
                printError(error.localizedDescription, hint: nil)
                exit(1)
            }
            return
        }

        // `start` runs NSApplication.shared.run() and MUST run directly on the main thread,
        // NOT inside an async @MainActor task (which would deadlock DispatchQueue.main).
        if remaining.first == "start" {
            let subArgs = Array(remaining.dropFirst())
            do {
                try MainActor.assumeIsolated {
                    try handleStartSync(args: subArgs, layout: layout)
                }
            } catch let err as MacBoxError {
                printError(err.localizedDescription, hint: err.recoveryHint)
                exit(1)
            } catch {
                printError(error.localizedDescription, hint: nil)
                exit(1)
            }
            return
        }

        Task {
            do {
                try await dispatch(remaining: remaining, layout: layout, jsonOutput: jsonOutput)
                exit(0)
            } catch let err as MacBoxError {
                printError(err.localizedDescription, hint: err.recoveryHint)
                exit(1)
            } catch {
                printError(error.localizedDescription, hint: nil)
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func dispatch(remaining: [String], layout: StorageLayout, jsonOutput: Bool) async throws {

        guard let command = remaining.first else {
            printUsage()
            return
        }
        let subArgs = Array(remaining.dropFirst())

        switch command {
        case "help", "-h", "--help":
            printUsage()

        case "doctor":
            let report = HostDiagnostics.run(layout: layout)
            if jsonOutput {
                try printJSON(report)
            } else {
                print("MacBox Doctor (\(report.dataDirectory))\n")
                for check in report.checks {
                    let icon: String
                    switch check.status {
                    case .pass: icon = "[OK]  "
                    case .warn: icon = "[WARN]"
                    case .fail: icon = "[FAIL]"
                    }
                    print("\(icon) \(check.title): \(check.detail)")
                    if let hint = check.hint {
                        print("       Підказка: \(hint)")
                    }
                }
            }
            if !report.ok {
                exit(1)
            }

        case "ready":
            guard subArgs.count <= 1 else { throw MacBoxError.invalidConfiguration("Використання: macbox ready [name]") }
            let report = try GuestReadiness.check(vm: subArgs.first ?? "default", layout: layout)
            if jsonOutput { try printJSON(report) }
            else { print("MacBox: \(report.state.rawValue) — \(report.message)") }
            if !report.isReady { exit(1) }

        case "image":
            let sub = subArgs.first ?? "info"
            switch sub {
            case "info":
                try HostDiagnostics.ensureHostRequirements(layout: layout)
                let (_, meta) = try await ImageManager.fetchLatestSupportedMetadata()
                if jsonOutput {
                    try printJSON(meta)
                } else {
                    print("Останній підтримуваний macOS IPSW:")
                    print("  Версія:  macOS \(meta.operatingSystemVersion) (\(meta.buildVersion))")
                    print("  Мін CPU: \(meta.minCPUs)")
                    print(String(format: "  Мін RAM: %.1f GiB", meta.minMemoryGiB))
                    print("  URL:     \(meta.url)")
                }
            default:
                throw MacBoxError.invalidConfiguration("Невідома підкоманда 'image \(sub)'. Використовуйте: macbox image info")
            }

        case "create":
            try await handleCreate(args: subArgs, layout: layout, jsonOutput: jsonOutput)

        case "ls":
            let names = try layout.listVMNames()
            if jsonOutput {
                struct VMListEntry: Codable {
                    let name: String
                    let installed: Bool
                    let running: Bool
                    let cpus: Int
                    let memoryGiB: Int
                    let diskGiB: Int
                }
                var entries: [VMListEntry] = []
                for name in names {
                    if let cfg = try? layout.loadConfig(named: name),
                       let paths = try? layout.vmPaths(named: name) {
                        entries.append(VMListEntry(
                            name: cfg.name,
                            installed: cfg.installed,
                            running: VMLock.isLocked(at: paths.lockFile),
                            cpus: cfg.cpuCount,
                            memoryGiB: cfg.memoryGiB,
                            diskGiB: cfg.diskGiB
                        ))
                    }
                }
                try printJSON(entries)
            } else if names.isEmpty {
                print("Немає створених VM у \(layout.vmsDirectory.path)")
            } else {
                for name in names {
                    let cfg = try? layout.loadConfig(named: name)
                    let paths = try? layout.vmPaths(named: name)
                    let running = paths.map { VMLock.isLocked(at: $0.lockFile) } ?? false
                    let state = running ? "running" : ((cfg?.installed ?? false) ? "stopped" : "incomplete")
                    let spec = cfg.map { "\($0.cpuCount) CPU, \($0.memoryGiB) GiB RAM, \($0.diskGiB) GiB disk" } ?? "?"
                    print("  \(name)\t[\(state)]\t\(spec)")
                }
            }
        case "status":
            guard let name = subArgs.first else {
                throw MacBoxError.invalidConfiguration("Вкажіть ім'я VM: macbox status <name>")
            }
            let cfg = try layout.loadConfig(named: name)
            let paths = try layout.vmPaths(named: name)
            let running = VMLock.isLocked(at: paths.lockFile)
            struct StatusPayload: Codable {
                let name: String
                let running: Bool
                let installed: Bool
                let offline: Bool
                let cpuCount: Int
                let memoryGiB: Int
                let diskGiB: Int
                let display: VMDisplayConfig
                let guestOSBuild: String?
            }
            let payload = StatusPayload(
                name: cfg.name,
                running: running,
                installed: cfg.installed,
                offline: cfg.offline,
                cpuCount: cfg.cpuCount,
                memoryGiB: cfg.memoryGiB,
                diskGiB: cfg.diskGiB,
                display: cfg.display,
                guestOSBuild: cfg.guestOSBuild
            )
            if jsonOutput {
                try printJSON(payload)
            } else {
                print("VM: \(cfg.name)")
                print("  Стан:     \(running ? "running" : "stopped")")
                print("  Встанов.: \(cfg.installed ? "так" : "ні")")
                print("  Ресурси:  \(cfg.cpuCount) CPU, \(cfg.memoryGiB) GiB RAM, \(cfg.diskGiB) GiB sparse disk")
                print("  Дисплей:  \(cfg.display.widthPixels)x\(cfg.display.heightPixels) @ \(cfg.display.pixelsPerInch) PPI (\(cfg.display.hiDPI ? "HiDPI" : "standard"))")
                print("  Мережа:   \(cfg.offline ? "offline (вимкнено)" : "NAT")")
            }

        case "start":
            break // Handled synchronously on the main thread in main()

        case "rm":
            guard let name = subArgs.first else {
                throw MacBoxError.invalidConfiguration("Вкажіть ім'я VM: macbox rm <name>")
            }
            let paths = try layout.vmPaths(named: name)
            guard FileManager.default.fileExists(atPath: paths.root.path) else {
                throw MacBoxError.vmNotFound(name)
            }
            if VMLock.isLocked(at: paths.lockFile) {
                throw MacBoxError.vmAlreadyRunning(name)
            }
            try FileManager.default.removeItem(at: paths.root)
            print("VM '\(name)' видалено.")

        default:
            throw MacBoxError.invalidConfiguration("Невідома команда '\(command)'. Запустіть 'macbox help'.")
        }
    }

    private static func handleCreate(args: [String], layout: StorageLayout, jsonOutput: Bool) async throws {
        guard let name = args.first, !name.hasPrefix("-") else {
            throw MacBoxError.invalidConfiguration("Вкажіть ім'я VM: macbox create <name> [--ipsw <path>] [--cpus 4] [--ram-gb 8] [--disk-gb 64] [--standard] [--offline] [--plan]")
        }
        try StorageLayout.validateVMName(name)

        var ipswPath: URL?
        var cpus = 4
        var ramGiB = 8
        var diskGiB = 64
        var display = VMDisplayConfig.defaultHiDPI
        var offline = false
        var planOnly = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--ipsw":
                i += 1
                guard i < args.count else { throw MacBoxError.invalidConfiguration("--ipsw потребує шлях до файлу") }
                ipswPath = URL(fileURLWithPath: NSString(string: args[i]).expandingTildeInPath)
            case "--cpus":
                i += 1
                guard i < args.count, let v = Int(args[i]), v > 0 else { throw MacBoxError.invalidConfiguration("--cpus потребує додатне число") }
                cpus = v
            case "--ram-gb":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 2 else { throw MacBoxError.invalidConfiguration("--ram-gb потребує число >= 2") }
                ramGiB = v
            case "--disk-gb":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 32 else { throw MacBoxError.invalidConfiguration("--disk-gb потребує число >= 32") }
                diskGiB = v
            case "--standard":
                display = .defaultStandard
            case "--hidpi":
                display = .defaultHiDPI
            case "--offline":
                offline = true
            case "--plan":
                planOnly = true
            default:
                throw MacBoxError.invalidConfiguration("Невідомий прапорець: \(arg)")
            }
            i += 1
        }

        if planOnly {
            let paths = try layout.vmPaths(named: name)
            print("План створення VM '\(name)' (без внесення змін):")
            print("  1. Перевірити вимоги хоста (Apple Silicon, macOS 14+, virtualization entitlement)")
            print("  2. IPSW: \(ipswPath?.path ?? "завантажити останній підтримуваний від Apple у \(layout.imagesDirectory.path)")")
            print("  3. Створити папку VM: \(paths.root.path)")
            print("  4. Створити sparse-диск: \(diskGiB) GiB")
            print("  5. Конфігурація: \(cpus) CPU, \(ramGiB) GiB RAM, \(display.widthPixels)x\(display.heightPixels) (\(display.hiDPI ? "HiDPI" : "standard")), мережа: \(offline ? "offline" : "NAT")")
            print("  6. Запустити VZMacOSInstaller для встановлення macOS")
            return
        }

        let options = VMInstaller.CreateOptions(
            name: name,
            ipswPath: ipswPath,
            cpuCount: cpus,
            memoryGiB: ramGiB,
            diskGiB: diskGiB,
            display: display,
            offline: offline
        )

        let created = try await VMInstaller.createAndInstall(options: options, layout: layout) { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        if jsonOutput {
            try printJSON(created)
        }
    }

    @MainActor
    private static func handleUpSync(args: [String], layout: StorageLayout) throws {
        var name: String?
        var ipsw: String?
        var plan = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--plan":
                guard !plan else { throw MacBoxError.invalidConfiguration("Повторний --plan") }
                plan = true
            case "--ipsw":
                index += 1
                guard index < args.count, ipsw == nil, !args[index].hasPrefix("-") else {
                    throw MacBoxError.invalidConfiguration("--ipsw потребує шлях до образу")
                }
                ipsw = args[index]
            default:
                guard !arg.hasPrefix("-"), name == nil else { throw MacBoxError.invalidConfiguration("Невідомий аргумент: \(arg)") }
                name = arg
            }
            index += 1
        }
        let machine = name ?? "default"
        let paths = try layout.vmPaths(named: machine)
        let exists = FileManager.default.fileExists(atPath: paths.root.path)
        let cfg = exists ? try layout.loadConfig(named: machine) : nil
        if let cfg, !cfg.installed {
            throw MacBoxError.invalidConfiguration("VM '\(machine)' встановлена не повністю. Перевірте її дані перед повторним створенням; MacBox не видаляє їх автоматично.")
        }
        let running = exists && VMLock.isLocked(at: paths.lockFile)
        if plan {
            let steps = running ? ["VM вже запущена"] : (exists ? ["Запустити існуючу VM"] : ["Перевірити Mac", "Використати IPSW або завантажити образ Apple", "Встановити macOS", "Запустити VM"])
            print("План для '\(machine)' (без змін):")
            for step in steps { print("  • \(step)") }
            print("  • Завершити налаштування гостя та надати дозволи за потреби")
            return
        }
        if running {
            let report = try GuestReadiness.check(vm: machine, layout: layout)
            print("VM '\(machine)' вже запущена. \(report.message)")
            if !report.isReady { exit(1) }
            return
        }
        if !exists {
            let process = Process()
            guard let executable = Bundle.main.executableURL else {
                throw MacBoxError.invalidConfiguration("Не вдалося визначити шлях до MacBox")
            }
            process.executableURL = executable
            var arguments = ["--data-dir", layout.baseDirectory.path, "create", machine]
            if let ipsw { arguments += ["--ipsw", ipsw] }
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw MacBoxError.invalidConfiguration("Не вдалося встановити VM; див. повідомлення вище.")
            }
        }
        FileHandle.standardError.write(Data("MacBox відкриє VM. Після входу відкрийте /Volumes/My Shared Files/tools/MacBoxGuest.app і надайте потрібні дозволи в гості. Перевірка: macbox ready \(machine).\n".utf8))
        try handleStartSync(args: [machine], layout: layout)
    }

    @MainActor
    private static func handleStartSync(args: [String], layout: StorageLayout) throws {
        guard let name = args.first, !name.hasPrefix("-") else {
            throw MacBoxError.invalidConfiguration("Вкажіть ім'я VM: macbox start <name> [--window] [--offline] [--recovery]")
        }
        let cfg = try layout.loadConfig(named: name)
        let paths = try layout.vmPaths(named: name)

        var offlineOverride: Bool?
        var recovery = false
        var proxyExecutable: URL?
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--window":
                break // Phase 1 Spike opens native VZVirtualMachineView window
            case "--offline":
                offlineOverride = true
            case "--recovery":
                recovery = true
            case "--vpn-proxy":
                index += 1
                guard index < args.count, args[index].hasPrefix("/"), proxyExecutable == nil else {
                    throw MacBoxError.invalidConfiguration("--vpn-proxy потребує абсолютний шлях до gvproxy")
                }
                proxyExecutable = URL(fileURLWithPath: args[index])
            default:
                throw MacBoxError.invalidConfiguration("Невідомий прапорець: \(arg)")
            }
            index += 1
        }

        let controller = SpikeWindowController(
            config: cfg,
            paths: paths,
            offlineOverride: offlineOverride,
            recovery: recovery,
            proxyExecutable: proxyExecutable
        )
        try controller.run()
    }

    private static func extractGlobalFlags(_ args: [String]) -> (dataDir: String?, json: Bool, remaining: [String]) {
        var dataDir: String?
        var json = false
        var remaining: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--data-dir", i + 1 < args.count {
                dataDir = NSString(string: args[i + 1]).expandingTildeInPath
                i += 2
            } else if arg == "--json" {
                json = true
                i += 1
            } else {
                remaining.append(arg)
                i += 1
            }
        }
        return (dataDir, json, remaining)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private static func printError(_ message: String, hint: String?) {
        FileHandle.standardError.write(Data("Помилка: \(message)\n".utf8))
        if let hint {
            FileHandle.standardError.write(Data("Підказка: \(hint)\n".utf8))
        }
    }

    private static func printUsage() {
        print("""
        MacBox — віртуальний Mac на Apple Silicon для ШІ-агентів (Phase 1 Spike)

        Використання:
          macbox up [name] [--ipsw <path>] [--plan]
          macbox ready [name] [--json]
          macbox doctor [--json] [--data-dir <path>]
          macbox image info [--json]
          macbox create <name> [--ipsw <path>] [--cpus 4] [--ram-gb 8] [--disk-gb 64] [--standard|--hidpi] [--offline] [--plan]
          macbox start <name> [--window] [--offline] [--recovery] [--vpn-proxy /path/to/gvproxy]
          macbox ls [--json]
          macbox status <name> [--json]
          macbox rm <name>
          macbox mcp [--data-dir <path>]
        """)
    }
}
