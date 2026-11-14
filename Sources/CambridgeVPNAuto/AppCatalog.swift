import AppKit
import Security
import CambridgeVPNAutoCore

enum AppCatalog {
    static func inspect(_ url: URL, route: AppRoute) throws -> AppConnectionRule {
        if url.pathExtension != "app" {
            guard isExecutableMachO(url) else { throw RoutingError("Choose an installed .app or signed executable") }
            return AppConnectionRule(name: url.lastPathComponent, bundlePath: url.path,
                                     identities: [try identity(at: url)], route: route)
        }
        guard let bundle = Bundle(url: url) else { throw RoutingError("Invalid application bundle") }
        let primary = try identity(at: url)
        var identities = [primary.signingIdentifier: primary]
        // Include embedded signed app, XPC and app-extension bundles. Do not use
        // a wildcard prefix: it could accidentally include unrelated apps.
        if let enumerator = FileManager.default.enumerator(at: url.appendingPathComponent("Contents"),
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey], options: [.skipsHiddenFiles]) {
            for case let child as URL in enumerator {
                let isBundle = ["app", "xpc", "appex"].contains(child.pathExtension)
                let resource = try? child.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
                let isBinary = resource?.isRegularFile == true && resource?.isExecutable == true && isExecutableMachO(child)
                guard isBundle || isBinary else { continue }
                // Shell scripts and unsigned resources are not code identities.
                if let item = try? identity(at: child) {
                    if let previous = identities[item.signingIdentifier], previous != item {
                        throw RoutingError("Conflicting signatures for \(item.signingIdentifier)")
                    }
                    identities[item.signingIdentifier] = item
                }
            }
        }
        return AppConnectionRule(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent,
            bundlePath: url.path, identities: identities.values.sorted { $0.signingIdentifier < $1.signingIdentifier }, route: route)
    }

    private static func isExecutableMachO(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard var header = try? file.read(upToCount: 32), header.count >= 16 else { return false }
        let magic = Array(header.prefix(4))
        if magic == [0xca, 0xfe, 0xba, 0xbe] || magic == [0xca, 0xfe, 0xba, 0xbf] {
            let width = magic.last == 0xbf ? 8 : 4
            guard header.count >= 16 + width else { return false }
            let offset = header[16..<(16 + width)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard (try? file.seek(toOffset: offset)) != nil,
                  let slice = try? file.read(upToCount: 16), slice.count == 16 else { return false }
            header = slice
        }
        let sliceMagic = Array(header.prefix(4))
        if sliceMagic == [0xcf, 0xfa, 0xed, 0xfe] || sliceMagic == [0xce, 0xfa, 0xed, 0xfe] {
            return Array(header[12..<16]) == [2, 0, 0, 0] // MH_EXECUTE, not a shared library.
        }
        if sliceMagic == [0xfe, 0xed, 0xfa, 0xcf] || sliceMagic == [0xfe, 0xed, 0xfa, 0xce] {
            return Array(header[12..<16]) == [0, 0, 0, 2]
        }
        return false
    }

    private static func identity(at url: URL) throws -> AppCodeIdentity {
        var code: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw RoutingError("A verifiable code signature was not found for \(url.lastPathComponent). Sign the app before adding a rule.")
        }
        return AppCodeIdentity(signingIdentifier: identifier, designatedRequirement: text as String)
    }
}
