import Testing
import Foundation
import MacBoxProtocol

@Suite("Control protocol") struct ControlProtocolTests {
    @Test func requestRoundTrip() throws {
        let request = ControlProtocol.Request(action: .drag(from: .init(x: 1, y: 2), to: .init(x: 100, y: 200)))
        let frame = try ControlProtocol.encodeFrame(request)
        let decoded = try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: frame)
        try decoded.validate()
        #expect(decoded == request)
    }
    @Test func invalidInputsAreRejected() throws {
        #expect(throws: ControlProtocol.ValidationError.invalidArgument) {
            try ControlProtocol.Request(action: .screenshotIfChanged("bad")).validate()
        }
        #expect(throws: ControlProtocol.ValidationError.invalidCoordinate) {
            try ControlProtocol.Request(action: .move(.init(x: -1, y: 0))).validate()
        }
        #expect(throws: ControlProtocol.ValidationError.invalidArgument) {
            try ControlProtocol.Request(action: .click(.init(x: 1, y: 1), button: .left, count: 4)).validate()
        }
        #expect(throws: ControlProtocol.ValidationError.invalidText) {
            try ControlProtocol.Request(action: .type(String(repeating: "a", count: ControlProtocol.maxTextBytes + 1))).validate()
        }
    }
    @Test func unchangedResponseRoundTrips() throws {
        let hash = String(repeating: "a", count: 64)
        let request = ControlProtocol.Request(action: .screenshotIfChanged(hash))
        try request.validate()
        let response = ControlProtocol.Response(id: request.id, result: .unchanged(hash: hash, width: 1280, height: 800))
        let frame = try ControlProtocol.encodeFrame(response)
        #expect(try ControlProtocol.decodeFrame(ControlProtocol.Response.self, from: frame) == response)
    }
    @Test func malformedFramesAreRejected() throws {
        #expect(throws: ControlProtocol.ValidationError.invalidFrame) {
            try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: Data([0, 0, 0, 1]))
        }
        #expect(throws: ControlProtocol.ValidationError.messageTooLarge) {
            try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: Data([255, 255, 255, 255]))
        }
    }
}

@Suite("Mailbox boundaries") struct MailboxTests {
    @Test func onlyOneAgentCanClaimARequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Mailbox(path: root.path)
        let second = try Mailbox(path: root.path)
        let id = UUID()
        var firstExecuted = false
        var secondExecuted = false
        let claimed = try first.withClaim(id) {
            firstExecuted = true
            let duplicate = try second.withClaim(id) { secondExecuted = true }
            #expect(!duplicate)
        }
        #expect(claimed && firstExecuted && !secondExecuted)
        #expect(try second.withClaim(id) {})
    }
    @Test func exchangesRegularFilesAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = try Mailbox(path: root.path)
        try box.publish(Data("hello".utf8), as: "request-ABC")
        #expect(try box.read("request-ABC") == Data("hello".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("response-ABC"), withDestinationURL: root.appendingPathComponent("request-ABC"))
        #expect(throws: Mailbox.Failure.invalidFile) { try box.read("response-ABC") }
        #expect(throws: Mailbox.Failure.invalidName) { try box.read("../outside") }
    }
    @Test func expiredActionsCannotRun() throws {
        var request = ControlProtocol.Request(action: .key("cmd+a"))
        request.expiresAt = Date().addingTimeInterval(-1)
        #expect(throws: ControlProtocol.ValidationError.expired) { try request.validate() }
    }
}

@Suite("Mailbox request cycle") struct MailboxCycleTests {
    @Test func requestAndResponseAreMatched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ControlProtocol.Request(action: .status)
        let worker = Task.detached { () throws -> Void in
            let box = try Mailbox(path: root.path)
            let name = "request-" + request.id.uuidString
            for _ in 0..<100 {
                if let data = try box.read(name) {
                    let decoded = try ControlProtocol.decodeFrame(ControlProtocol.Request.self, from: data)
                    try decoded.validate()
                    let response = ControlProtocol.Response(id: decoded.id, result: .ok)
                    try box.publish(ControlProtocol.encodeFrame(response), as: "response-" + decoded.id.uuidString)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Mailbox.Failure.timeout
        }
        let response = try Mailbox(path: root.path).request(request, timeout: 2)
        try await worker.value
        #expect(response.id == request.id)
        #expect(response.result == .ok)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
