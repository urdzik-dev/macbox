import Foundation
import Security

/// Compares the staged update against the installed app's designated requirement.
/// Validation must happen after copying into private staging and immediately before replacement.
public enum AgentIdentity {
    public enum Failure: Error, Equatable { case invalidInstalled(OSStatus), invalidCandidate(OSStatus) }

    public static func validateUpdate(installed: URL, candidate: URL) throws {
        var installedCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode)
        guard status == errSecSuccess, let trusted = installedCode else { throw Failure.invalidInstalled(status) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(trusted, flags, nil)
        guard status == errSecSuccess else { throw Failure.invalidInstalled(status) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(trusted, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw Failure.invalidInstalled(status) }
        var candidateCode: SecStaticCode?
        status = SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode)
        guard status == errSecSuccess, let update = candidateCode else { throw Failure.invalidCandidate(status) }
        status = SecStaticCodeCheckValidity(update, flags, requirement)
        guard status == errSecSuccess else { throw Failure.invalidCandidate(status) }
    }
}
