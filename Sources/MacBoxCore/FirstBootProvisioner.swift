import Foundation
import Security
import Virtualization

public enum FirstBootProvisioner {
    public enum Failure: LocalizedError {
        case requiresNewSDK, requiresNewHost, invalidState, keychain(OSStatus), random(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .requiresNewSDK: return "Для автоматичного налаштування macOS 27 потрібна збірка MacBox із SDK macOS 27. Оновіть Xcode і запустіть setup.sh знову."
            case .requiresNewHost: return "Для автоматичного налаштування гостьової macOS 27 потрібен хост macOS 27 або новіший. VM не запущена."
            case .invalidState: return "Немає ідентифікатора для автоматичного створення облікового запису. VM не запущена."
            case let .keychain(status): return "Не вдалося зберегти пароль гостьового користувача у Keychain (код \(status))."
            case let .random(status): return "Не вдалося створити випадковий пароль (код \(status))."
            }
        }
    }

    /// Provision only newly installed macOS 27 guests. Existing VMs are never reconfigured.
    public static func shouldProvision(_ config: VMConfig, hostMajor: Int) -> Bool {
        guard hostMajor >= 27, config.firstBootPending == true,
              let version = config.guestOSVersion,
              let major = Int(version.split(separator: ".").first ?? ""), major >= 27 else { return false }
        return true
    }

    public static func configure(_ options: VZMacOSVirtualMachineStartOptions, config: VMConfig) throws -> Bool {
        let hostMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if config.firstBootPending == true, let version = config.guestOSVersion,
           let part = version.split(separator: ".").first, let major = Int(part), major >= 27, hostMajor < 27 {
            throw Failure.requiresNewHost
        }
        if hostMajor >= 27, config.firstBootPending == true {
            guard let version = config.guestOSVersion,
                  let part = version.split(separator: ".").first, Int(part) != nil else { throw Failure.invalidState }
        }
        guard shouldProvision(config, hostMajor: hostMajor) else { return false }
        guard let id = config.provisioningID else { throw Failure.invalidState }
        #if MACBOX_HAS_MACOS27_SDK
        if #available(macOS 27.0, *) {
            let guest = VZMacGuestProvisioningOptions()
            guest.fullName = "MacBox User"
            guest.username = "macbox"
            guest.password = try password(for: id)
            guest.logsInAutomatically = true
            guest.enablesRemoteLogin = false
            try options.setGuestProvisioning(guest)
            return true
        }
        throw Failure.requiresNewSDK
        #else
        _ = id
        throw Failure.requiresNewSDK
        #endif
    }

    /// One credential per VM identity, stored in the user's login keychain, never argv or config.json.
    private static func password(for id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: "ua.macbox.guest-account",
                                     kSecAttrAccount as String: id.uuidString]
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let found = SecItemCopyMatching(lookup as CFDictionary, &result)
        if found == errSecSuccess {
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.invalidState }
            return value
        }
        guard found == errSecItemNotFound else { throw Failure.keychain(found) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw Failure.random(randomStatus) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "MacBox guest \(id.uuidString)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return value
    }
}
