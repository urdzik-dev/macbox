import Foundation

public enum MacBoxError: Error, LocalizedError, Sendable {
    case unsupportedArchitecture(String)
    case unsupportedMacOSVersion(String)
    case missingVirtualizationEntitlement
    case invalidVMName(String)
    case vmAlreadyExists(String)
    case vmNotFound(String)
    case vmAlreadyRunning(String)
    case insufficientDiskSpace(availableGiB: Double, requiredGiB: Double)
    case missingFile(String)
    case invalidConfiguration(String)
    case restoreImageUnavailable(String)
    case installationFailed(String)
    case virtualizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Непідтримувана архітектура: \(arch). MacBox підтримує лише Apple Silicon (arm64)."
        case .unsupportedMacOSVersion(let version):
            return "Непідтримувана версія macOS: \(version). Потрібна macOS 14.0 (Sonoma) або новіша."
        case .missingVirtualizationEntitlement:
            return "Відсутній entitlement 'com.apple.security.virtualization'."
        case .invalidVMName(let name):
            return "Некоректне ім'я VM '\(name)'. Дозволені лише латинські літери, цифри, '-' і '_' (1..64 символи)."
        case .vmAlreadyExists(let name):
            return "VM '\(name)' вже існує."
        case .vmNotFound(let name):
            return "VM '\(name)' не знайдено."
        case .vmAlreadyRunning(let name):
            return "VM '\(name)' вже запущена іншим процесом (активний файл блокування)."
        case .insufficientDiskSpace(let available, let required):
            return String(format: "Недостатньо місця на диску: вільно %.1f GiB, рекомендовано щонайменше %.1f GiB.", available, required)
        case .missingFile(let path):
            return "Очікуваний файл не знайдено: \(path)"
        case .invalidConfiguration(let reason):
            return "Невалідна конфігурація VM: \(reason)"
        case .restoreImageUnavailable(let reason):
            return "Не вдалося отримати IPSW-образ macOS: \(reason)"
        case .installationFailed(let reason):
            return "Помилка встановлення macOS у VM: \(reason)"
        case .virtualizationFailed(let reason):
            return "Помилка Virtualization.framework: \(reason)"
        }
    }

    public var recoveryHint: String? {
        switch self {
        case .unsupportedArchitecture:
            return "Запустіть MacBox на Mac із процесором Apple Silicon (M1/M2/M3/M4)."
        case .unsupportedMacOSVersion:
            return "Оновіть хостову macOS до версії 14.0 або новішої."
        case .missingVirtualizationEntitlement:
            return "Підпишіть бінарник за допомогою './scripts/build-and-sign.sh' або: codesign --force --sign - --entitlements MacBox.entitlements <binary>"
        case .insufficientDiskSpace:
            return "Звільніть місце на диску або вкажіть інший APFS-том через --data-dir /Volumes/<Disk>/macbox."
        case .vmAlreadyRunning(let name):
            return "Перевірте статус командою 'macbox status \(name)' або зупиніть запущений процес."
        default:
            return nil
        }
    }
}
