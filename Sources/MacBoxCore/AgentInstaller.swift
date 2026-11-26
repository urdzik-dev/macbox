import Foundation
import Darwin

/// First installation never replaces a pre-existing application.
public enum AgentInstaller {
    public enum UpdateFailure: Error { case invalidVersion, swapFailed(Int32) }
    public static func installIfAbsent(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return false }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".macbox-stage-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        try AgentIdentity.validateUpdate(installed: source, candidate: stage)
        // moveItem fails if another application appears at the destination.
        try fm.moveItem(at: stage, to: destination)
        return true
    }

    /// Installs only a newer, signature-matching bundle. The previous bundle is retained as a backup.
    public static func upgradeIfNewer(source: URL, destination: URL) throws -> URL? {
        func version(_ url: URL) throws -> UInt64 {
            let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = info["CFBundleVersion"] as? String,
                  let number = UInt64(value), number > 0 else { throw UpdateFailure.invalidVersion }
            return number
        }
        let current = try version(destination)
        guard try version(source) > current else { return nil }
        let parent = destination.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".macbox-backup-\(UUID().uuidString).app")
        let fm = FileManager.default
        try fm.copyItem(at: source, to: backup)
        var swapped = false
        defer { if !swapped { try? fm.removeItem(at: backup) } }
        guard try version(backup) > current else { throw UpdateFailure.invalidVersion }
        try AgentIdentity.validateUpdate(installed: destination, candidate: backup)
        guard renameatx_np(AT_FDCWD, destination.path, AT_FDCWD, backup.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure.swapFailed(errno)
        }
        swapped = true
        return backup
    }

    public static func rollback(destination: URL, backup: URL) throws {
        guard renameatx_np(AT_FDCWD, destination.path, AT_FDCWD, backup.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure.swapFailed(errno)
        }
    }
}
