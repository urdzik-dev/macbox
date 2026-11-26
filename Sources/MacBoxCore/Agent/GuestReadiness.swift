import Foundation
import ImageIO
import MacBoxProtocol

public struct GuestReadiness: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready, vmStopped, agentUnavailable, permissionsRequired, captureFailed, protocolError
    }
    public let vm: String
    public let state: State
    public let message: String
    public let screenRecording: Bool?
    public let accessibility: Bool?
    public var isReady: Bool { state == .ready }

    public static func check(vm: String, layout: StorageLayout, timeout: TimeInterval = 3) throws -> GuestReadiness {
        _ = try layout.loadConfig(named: vm)
        let paths = try layout.vmPaths(named: vm)
        guard VMLock.isLocked(at: paths.lockFile) else {
            return .init(vm: vm, state: .vmStopped, message: "VM вимкнена. Запустіть: macbox up \(vm)", screenRecording: nil, accessibility: nil)
        }
        do {
            let box = try Mailbox(path: paths.exchange.path)
            let status = try box.request(.init(action: .status), timeout: timeout)
            guard case let .status(screen, access) = status.result else {
                return .init(vm: vm, state: .protocolError, message: "Агент повернув неочікувану відповідь на запит стану.", screenRecording: nil, accessibility: nil)
            }
            guard screen && access else {
                var missing: [String] = []
                if !screen { missing.append("Screen Recording") }
                if !access { missing.append("Accessibility") }
                return .init(vm: vm, state: .permissionsRequired, message: "У гостьовій macOS надайте MacBox Guest дозволи: \(missing.joined(separator: ", ")). Перевірте копію, яку запущено, і перезапустіть агент.", screenRecording: screen, accessibility: access)
            }
            let image = try box.request(.init(action: .screenshot), timeout: timeout)
            guard case let .imagePNG(data, width, height) = image.result,
                  width > 0, height > 0, width <= ControlProtocol.maxCoordinate, height <= ControlProtocol.maxCoordinate,
                  width * height <= 16_777_216,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.png",
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == width,
                  properties[kCGImagePropertyPixelHeight] as? Int == height else {
                return .init(vm: vm, state: .captureFailed, message: "Дозволи є, але отримати коректний скріншот не вдалося. Перезапустіть MacBox Guest і перевірте вхід у гостьову сесію.", screenRecording: screen, accessibility: access)
            }
            return .init(vm: vm, state: .ready, message: "Агент відповідає, дозволи активні, скріншот отримано (\(width)×\(height)).", screenRecording: screen, accessibility: access)
        } catch Mailbox.Failure.timeout {
            return .init(vm: vm, state: .agentUnavailable, message: "Агент не відповідає. Увійдіть у гостьову macOS і відкрийте /Volumes/My Shared Files/tools/MacBoxGuest.app.", screenRecording: nil, accessibility: nil)
        } catch Mailbox.Failure.directory {
            return .init(vm: vm, state: .agentUnavailable, message: "Канал агента недоступний. Переконайтеся, що VM запущена поточною збіркою MacBox.", screenRecording: nil, accessibility: nil)
        } catch {
            return .init(vm: vm, state: .protocolError, message: "Помилка каналу агента: \(error.localizedDescription)", screenRecording: nil, accessibility: nil)
        }
    }
}
