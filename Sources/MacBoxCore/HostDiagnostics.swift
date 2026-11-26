import Foundation
import Security

public struct DiagnosticCheck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pass
        case warn
        case fail
    }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    public let hint: String?

    public init(id: String, title: String, status: Status, detail: String, hint: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.hint = hint
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public let checks: [DiagnosticCheck]
    public let dataDirectory: String

    public var ok: Bool {
        !checks.contains { $0.status == .fail }
    }

    public init(checks: [DiagnosticCheck], dataDirectory: String) {
        self.checks = checks
        self.dataDirectory = dataDirectory
    }
}

public enum HostDiagnostics {
    public static func run(layout: StorageLayout) -> DiagnosticReport {
        var checks: [DiagnosticCheck] = []

        // 1. Architecture check
        let arch = currentArchitecture()
        if arch == "arm64" {
            checks.append(DiagnosticCheck(
                id: "arch",
                title: "Архітектура CPU",
                status: .pass,
                detail: "Apple Silicon (arm64)"
            ))
        } else {
            checks.append(DiagnosticCheck(
                id: "arch",
                title: "Архітектура CPU",
                status: .fail,
                detail: arch,
                hint: "MacBox потребує Mac на Apple Silicon (arm64)."
            ))
        }

        // 2. macOS version check
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        if osVersion.majorVersion >= 14 {
            checks.append(DiagnosticCheck(
                id: "macos",
                title: "Версія macOS",
                status: .pass,
                detail: "macOS \(versionString)"
            ))
        } else {
            checks.append(DiagnosticCheck(
                id: "macos",
                title: "Версія macOS",
                status: .fail,
                detail: "macOS \(versionString)",
                hint: "Оновіть хост до macOS 14.0 (Sonoma) або новішої."
            ))
        }

        // 3. Virtualization entitlement check
        let hasEntitlement = hasVirtualizationEntitlement()
        if hasEntitlement {
            checks.append(DiagnosticCheck(
                id: "entitlement",
                title: "Entitlement віртуалізації",
                status: .pass,
                detail: "com.apple.security.virtualization присутній"
            ))
        } else {
            checks.append(DiagnosticCheck(
                id: "entitlement",
                title: "Entitlement віртуалізації",
                status: .fail,
                detail: "com.apple.security.virtualization відсутній",
                hint: "Підпишіть бінарник через './scripts/build-and-sign.sh' або codesign --entitlements MacBox.entitlements."
            ))
        }

        // 4. Disk space check
        if let availGiB = availableDiskSpaceGiB(at: layout.baseDirectory) {
            let formatted = String(format: "%.1f GiB вільно", availGiB)
            if availGiB >= 50 {
                checks.append(DiagnosticCheck(
                    id: "disk",
                    title: "Вільне місце на диску",
                    status: .pass,
                    detail: "\(formatted) (\(layout.baseDirectory.path))"
                ))
            } else if availGiB >= 25 {
                checks.append(DiagnosticCheck(
                    id: "disk",
                    title: "Вільне місце на диску",
                    status: .warn,
                    detail: "\(formatted) (\(layout.baseDirectory.path))",
                    hint: "Для IPSW (~15 GiB) + встановленої VM (~20 GiB) + снапшотів бажано >= 50 GiB або зовнішній APFS-диск (--data-dir)."
                ))
            } else {
                checks.append(DiagnosticCheck(
                    id: "disk",
                    title: "Вільне місце на диску",
                    status: .fail,
                    detail: "\(formatted) (\(layout.baseDirectory.path))",
                    hint: "Замало місця для створення macOS VM. Звільніть простір або вкажіть --data-dir."
                ))
            }
        } else {
            checks.append(DiagnosticCheck(
                id: "disk",
                title: "Вільне місце на диску",
                status: .warn,
                detail: "Не вдалося визначити вільний простір для \(layout.baseDirectory.path)"
            ))
        }

        return DiagnosticReport(checks: checks, dataDirectory: layout.baseDirectory.path)
    }

    public static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static func hasVirtualizationEntitlement() -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let sCode = staticCode else {
            return false
        }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(sCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let value = entitlements["com.apple.security.virtualization"] as? Bool
        else {
            return false
        }
        return value
    }

    public static func availableDiskSpaceGiB(at url: URL) -> Double? {
        var checkURL = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: checkURL.path) {
            let parent = checkURL.deletingLastPathComponent()
            if parent.path == checkURL.path { break }
            checkURL = parent
        }
        guard let values = try? checkURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else {
            return nil
        }
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 {
            return Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        }
        if let bytes = values.volumeAvailableCapacity, bytes > 0 {
            return Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        }
        return nil
    }

    public static func ensureHostRequirements(layout: StorageLayout) throws {
        let arch = currentArchitecture()
        if arch != "arm64" {
            throw MacBoxError.unsupportedArchitecture(arch)
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if osVersion.majorVersion < 14 {
            throw MacBoxError.unsupportedMacOSVersion("\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        }
        if !hasVirtualizationEntitlement() {
            throw MacBoxError.missingVirtualizationEntitlement
        }
    }
}
