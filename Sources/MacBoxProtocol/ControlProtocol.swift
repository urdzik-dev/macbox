import Foundation

/// Wire messages are untrusted on both sides of the VM boundary.
public enum ControlProtocol {
    public static let version = 1
    public static let maxMessageBytes = 32 * 1_048_576
    public static let maxTextBytes = 65_536
    public static let maxCoordinate = 32_768

    public enum ValidationError: Error, Equatable {
        case unsupportedVersion, invalidCoordinate, invalidText, invalidArgument, messageTooLarge, invalidFrame, expired
    }

    public struct Request: Codable, Equatable, Sendable {
        public var version: Int
        public var id: UUID
        public var expiresAt: Date
        public var action: Action
        public init(id: UUID = UUID(), action: Action) {
            self.version = ControlProtocol.version
            self.id = id
            self.expiresAt = Date().addingTimeInterval(15)
            self.action = action
        }
        public func validate() throws {
            guard version == ControlProtocol.version else { throw ValidationError.unsupportedVersion }
            guard expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 30 else { throw ValidationError.expired }
            try action.validate()
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
        func validate() throws {
            guard (0...ControlProtocol.maxCoordinate).contains(x), (0...ControlProtocol.maxCoordinate).contains(y) else {
                throw ValidationError.invalidCoordinate
            }
        }
    }

    public enum Action: Codable, Equatable, Sendable {
        case status
        case screenshot
        case screenshotIfChanged(String)
        case click(Point, button: MouseButton, count: Int)
        case move(Point)
        case drag(from: Point, to: Point)
        case scroll(Point, dx: Int, dy: Int)
        case type(String)
        case key(String)

        func validate() throws {
            switch self {
            case .status, .screenshot: break
            case let .screenshotIfChanged(hash):
                guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ValidationError.invalidArgument }
            case let .click(point, _, count):
                try point.validate()
                guard (1...3).contains(count) else { throw ValidationError.invalidArgument }
            case let .move(point): try point.validate()
            case let .drag(from, to): try from.validate(); try to.validate()
            case let .scroll(point, dx, dy):
                try point.validate()
                guard (-10_000...10_000).contains(dx), (-10_000...10_000).contains(dy) else { throw ValidationError.invalidArgument }
            case let .type(value):
                guard value.utf8.count <= ControlProtocol.maxTextBytes else { throw ValidationError.invalidText }
            case let .key(value):
                guard !value.isEmpty, value.utf8.count <= 128, !value.contains("\n") else { throw ValidationError.invalidArgument }
            }
        }
    }
    public enum MouseButton: String, Codable, Sendable { case left, right, middle }

    public struct Response: Codable, Equatable, Sendable {
        public let version: Int
        public let id: UUID
        public let result: Result
        public init(id: UUID, result: Result) { self.version = ControlProtocol.version; self.id = id; self.result = result }
    }
    public enum Result: Codable, Equatable, Sendable {
        case ok
        case status(screenRecording: Bool, accessibility: Bool)
        case imagePNG(Data, width: Int, height: Int)
        case unchanged(hash: String, width: Int, height: Int)
        case failure(code: String, message: String)
    }

    /// Four-byte big-endian length followed by UTF-8 JSON; callers must enforce timeouts.
    public static func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maxMessageBytes else { throw ValidationError.messageTooLarge }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        return frame
    }

    /// Consumes a complete frame only. Reject lengths before allocating or decoding payloads.
    public static func decodeFrame<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= 4 else { throw ValidationError.invalidFrame }
        let size = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= maxMessageBytes else { throw ValidationError.messageTooLarge }
        guard frame.count == Int(size) + 4 else { throw ValidationError.invalidFrame }
        return try JSONDecoder().decode(type, from: frame.dropFirst(4))
    }
}
