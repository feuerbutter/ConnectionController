import Foundation
import Security

/// Verify the OS-provided source audit token, not a process name or path prefix.
public struct FlowIdentity {
    private let code: SecCode?
    public let signingIdentifier: String
    public init(auditToken: Data?, fallbackIdentifier: String = "") {
        var guest: SecCode?
        var identifier = fallbackIdentifier
        if let auditToken,
           SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: auditToken] as CFDictionary,
                                          [], &guest) == errSecSuccess, let guest {
            var info: CFDictionary?
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let values = info as? [String: Any], let found = values[kSecCodeInfoIdentifier as String] as? String {
                identifier = found
            }
        }
        self.code = guest
        self.signingIdentifier = identifier
    }
    public func verifies(_ identity: AppCodeIdentity) -> Bool {
        guard identity.signingIdentifier == signingIdentifier, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(identity.designatedRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
