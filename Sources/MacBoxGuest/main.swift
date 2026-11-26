import Foundation
import AppKit
@preconcurrency import ApplicationServices
import Darwin
import MacBoxProtocol
import MacBoxCore
import ServiceManagement
import CryptoKit

// Accidental host execution is forbidden. This is not a security attestation.
func isVirtualMac() -> Bool {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return false }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return false }
    return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("VirtualMac")
}

guard isVirtualMac() else {
    FileHandle.standardError.write(Data("MacBox guest agent runs only in a virtual Mac.\n".utf8))
    exit(1)
}

func readExactly(_ count: Int) throws -> Data? {
    var result = Data()
    while result.count < count {
        guard let part = try FileHandle.standardInput.read(upToCount: count - result.count), !part.isEmpty else {
            if result.isEmpty { return nil }
            throw ControlProtocol.ValidationError.invalidFrame
        }
        result.append(part)
    }
    return result
}
@Sendable nonisolated func post(_ type: CGEventType, at p: ControlProtocol.Point, button: CGMouseButton = .left, count: Int = 1) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: button) else {
        throw GuestError.event
    }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
    event.post(tap: .cghidEventTap)
}
enum GuestError: LocalizedError {
    case event, screenPermission, accessibilityPermission, capture, unsupported

    var errorDescription: String? {
        switch self {
        case .event: return "Не вдалося створити подію вводу."
        case .screenPermission: return "Гостьовому MacBox Guest потрібен дозвіл Screen Recording."
        case .accessibilityPermission: return "Гостьовому MacBox Guest потрібен дозвіл Accessibility."
        case .capture: return "Не вдалося захопити гостьовий екран."
        case .unsupported: return "Ця клавіша або дія поки не підтримується."
        }
    }
}
@Sendable nonisolated func keyEvent(_ specification: String) throws {
    let parts = specification.lowercased().split(separator: "+").map(String.init)
    guard let name = parts.last, !name.isEmpty else { throw GuestError.unsupported }
    let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
    guard let code = codes[name] else { throw GuestError.unsupported }
    var flags = CGEventFlags()
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: throw GuestError.unsupported
        }
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw GuestError.event }
    down.flags = flags; up.flags = flags
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
}
@Sendable nonisolated func execute(_ action: ControlProtocol.Action) throws -> ControlProtocol.Result {
    if case .status = action { return .status(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted()) }
    let previousHash: String?
    switch action {
    case .screenshot: previousHash = nil
    case let .screenshotIfChanged(hash): previousHash = hash
    default: previousHash = nil
    }
    if action == .screenshot || previousHash != nil {
        guard CGPreflightScreenCaptureAccess() else { throw GuestError.screenPermission }
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, let image = CGDisplayCreateImage(display),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GuestError.capture }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { throw GuestError.capture }
        if let previousHash {
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            if hash == previousHash { return .unchanged(hash: hash, width: width, height: height) }
        }
        return .imagePNG(png, width: width, height: height)
    }
    guard AXIsProcessTrusted() else { throw GuestError.accessibilityPermission }
    switch action {
    case let .move(p): try post(.mouseMoved, at: p)
    case let .click(p, button, count):
        let mouse: CGMouseButton = button == .left ? .left : (button == .right ? .right : .center)
        let down: CGEventType = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        let up: CGEventType = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        for n in 1...count { try post(down, at: p, button: mouse, count: n); try post(up, at: p, button: mouse, count: n) }
    case let .drag(from, to):
        try post(.leftMouseDown, at: from)
        try post(.leftMouseDragged, at: to)
        try post(.leftMouseUp, at: to)
    case let .scroll(p, dx, dy):
        try post(.mouseMoved, at: p)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { throw GuestError.event }
        event.post(tap: .cghidEventTap)
    case let .type(text):
        for scalar in text.unicodeScalars {
            let chars = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw GuestError.event }
            chars.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    case let .key(value): try keyEvent(value)
    case .status, .screenshot, .screenshotIfChanged: break
    }
    return .ok
}

@Sendable nonisolated func serveMailbox(_ path: String) throws {
    let box = try Mailbox(path: path)
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    while true {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasPrefix("request-") {
            let suffix = String(name.dropFirst("request-".count))
            guard let id = UUID(uuidString: suffix), suffix == id.uuidString else { continue }
            do {
                _ = try box.withClaim(id) {
                    do {
                        guard let frame = try box.read(name) else { return }
                        try box.remove(name)
                        let request = try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: frame)
                        guard request.id == id else { return }
                        let result: ControlProtocol.Result
                        do { try request.validate(); result = try execute(request.action) }
                        catch { result = .failure(code: "guest_error", message: error.localizedDescription) }
                        try box.publish(ControlProtocol.encodeFrame(ControlProtocol.Response(id: id, result: result)), as: "response-" + suffix)
                    } catch { try? box.remove(name) }
                }
            } catch { /* A failed claim must not remove another agent's request. */ }
        }
        usleep(30_000)
    }
}

@MainActor final class SetupWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var details: NSTextField!
    private var timer: Timer?
    private var updateTimer: Timer?
    private var loginStatus = "Перевірка автозапуску…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bounds = NSRect(x: 0, y: 0, width: 620, height: 260)
        window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Налаштування MacBox Guest"
        window.center()
        let title = NSTextField(labelWithString: "Підключення гостьового Mac")
        title.font = .boldSystemFont(ofSize: 20)
        title.frame = NSRect(x: 24, y: 210, width: 572, height: 28)
        details = NSTextField(wrappingLabelWithString: "Перевірка дозволів…")
        details.frame = NSRect(x: 24, y: 94, width: 572, height: 104)
        let screen = NSButton(title: "Дозволити запис екрана", target: self, action: #selector(requestScreen))
        screen.frame = NSRect(x: 24, y: 50, width: 230, height: 30)
        let access = NSButton(title: "Дозволити керування", target: self, action: #selector(requestAccessibility))
        access.frame = NSRect(x: 270, y: 50, width: 230, height: 30)
        for item in [title, details!, screen, access] { window.contentView?.addSubview(item) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/") {
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                loginStatus = SMAppService.mainApp.status == .enabled ? "автозапуск увімкнено" : "автозапуск очікує підтвердження в параметрах входу"
            } catch { loginStatus = "помилка автозапуску: \(error.localizedDescription)" }
        } else { loginStatus = "автозапуск доступний після встановлення в Applications" }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if Bundle.main.bundleURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/") {
            updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkForUpdate() }
            }
        }
        Thread.detachNewThread {
            do { try serveMailbox("/Volumes/My Shared Files/control") }
            catch { FileHandle.standardError.write(Data("MacBox guest channel: \(error)\n".utf8)) }
        }
    }
    private func checkForUpdate() {
        let source = URL(fileURLWithPath: "/Volumes/My Shared Files/tools/MacBoxGuest.app")
        let destination = Bundle.main.bundleURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            guard let backup = try AgentInstaller.upgradeIfNewer(source: source, destination: destination) else { return }
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-n", destination.path]
            do {
                try launcher.run(); launcher.waitUntilExit()
                if launcher.terminationStatus == 0 { NSApp.terminate(nil); return }
                try AgentInstaller.rollback(destination: destination, backup: backup)
                loginStatus = "оновлення скасовано: новий агент не запущено"
            } catch {
                try? AgentInstaller.rollback(destination: destination, backup: backup)
                loginStatus = "помилка запуску оновлення: \(error.localizedDescription)"
            }
        } catch { loginStatus = "оновлення не застосовано: \(error.localizedDescription)" }
        refresh()
    }
    private func refresh() {
        let screen = CGPreflightScreenCaptureAccess() ? "дозволено" : "потрібен дозвіл"
        let access = AXIsProcessTrusted() ? "дозволено" : "потрібен дозвіл"
        details.stringValue = "Запис екрана: \(screen)\nКерування: \(access)\nЗастосунок: \(Bundle.main.bundleURL.path)\nАвтозапуск: \(loginStatus)\nПісля зміни дозволів перезапустіть MacBox Guest."
    }
    @objc private func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

do {
    if Bundle.main.bundleIdentifier == "ua.macbox.guest" {
        let source = Bundle.main.bundleURL.standardizedFileURL
        if source.path.hasPrefix("/Volumes/My Shared Files/tools/") {
            let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MacBoxGuest.app")
            do {
                let installed = try AgentInstaller.installIfAbsent(source: source, destination: destination)
                var backup: URL?
                if !installed {
                    do { backup = try AgentInstaller.upgradeIfNewer(source: source, destination: destination) }
                    catch { FileHandle.standardError.write(Data("Оновлення агента відхилено; використовується встановлена копія: \(error.localizedDescription)\n".utf8)) }
                }
                try AgentIdentity.validateUpdate(installed: destination, candidate: destination)
                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                launcher.arguments = ["-n", destination.path]
                do {
                    try launcher.run(); launcher.waitUntilExit()
                    if launcher.terminationStatus == 0 { exit(0) }
                } catch {
                    if let backup { try? AgentInstaller.rollback(destination: destination, backup: backup) }
                    throw error
                }
                if let backup { try? AgentInstaller.rollback(destination: destination, backup: backup) }
                FileHandle.standardError.write(Data("Не вдалося запустити встановлену копію агента.\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("Автоматичне встановлення не виконане: \(error.localizedDescription)\n".utf8))
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = SetupWindow()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    } else if CommandLine.arguments.contains("--mailbox") {
        try serveMailbox("/Volumes/My Shared Files/control")
    } else {
        while let header = try readExactly(4) {
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= ControlProtocol.maxMessageBytes, let body = try readExactly(Int(length)) else { throw ControlProtocol.ValidationError.invalidFrame }
            let request = try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: header + body)
            let result: ControlProtocol.Result
            do { try request.validate(); result = try execute(request.action) }
            catch { result = .failure(code: "guest_error", message: error.localizedDescription) }
            let response = ControlProtocol.Response(id: request.id, result: result)
            try FileHandle.standardOutput.write(contentsOf: ControlProtocol.encodeFrame(response))
        }
    }
} catch {
    FileHandle.standardError.write(Data("MacBox guest protocol error: \(error)\n".utf8))
    exit(1)
}
