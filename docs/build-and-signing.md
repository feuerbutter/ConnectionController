# Build, signing and distribution

## Local development

Install Xcode and select its developer tools. The Swift package builds the host, router,
Objective-C bridge and framework-free core checks with the local Mac's architecture.

```sh
swift run CambridgeVPNAutoCoreChecks
swift build -c release
python3 scripts/build-connection-manager.py --preview
```

Open the path printed after `BUILD=`. The preview has its own bundle identity and disables
the controller and routing activation. It can be used for UI development without paid
signing. `swift run CambridgeVPNAuto --vpn-service` and `--status` are read-only diagnostics.
Avoid running a second ordinary `--agent` controller alongside an installed copy.

## Using a release from the maintainer

The recipient needs no paid developer account. Copy the notarized app into `/Applications`,
open it, add the desired app rules, choose Apply, and approve the system-extension and
network-configuration prompts. Configure and verify one enabled native IPSec VPN profile
in macOS settings first. A vendor-specific VPN app may not expose the service this code expects.
The installed release currently uses ConnectionManager as its app name.

Developer ID profiles permit distribution to other Macs. They have long validity periods
and do not impose a seven-day reinstall cycle. Profile expiration or certificate revocation
can still affect launch. Apple's free Personal Team provisioning limitations should not
be applied to an already Developer ID–signed distribution app.

The maintainer's previous 2.1.2 (12) release is arm64-only. Check the architecture of both
host and router when preparing an Intel or universal distribution. The current notarization
wrapper records arm64 in archive metadata and needs adjustment for another architecture.
The Xcode App Store project's universal architecture setting is a separate build route.

## Developer ID build

Both bundles need matching Developer ID provisioning profiles and a Developer ID Application
identity under the same signing team. Their restricted capabilities are as follows.

| Bundle | Existing identifier | Required capabilities |
| --- | --- | --- |
| Host | `com.wjli.cambridge-vpn-auto` | App proxy and content filter system extensions, system-extension installation |
| Router | `com.wjli.cambridge-vpn-auto.connection-router` | App proxy and content filter system extensions |

The direct-distribution entitlement values use `app-proxy-provider-systemextension` and
`content-filter-provider-systemextension`. The build script derives the signing team and
application group from the supplied profiles and signs the router before the host.

```sh
python3 scripts/build-connection-manager.py \
  --identity 'Developer ID Application: YOUR NAME (TEAM_ID)' \
  --app-profile /absolute/path/host.provisionprofile \
  --extension-profile /absolute/path/router.provisionprofile
```

An independent signer must register identifiers under their own team and update the
matching bundle IDs, extension lookup identifiers, Mach service/application group and
profile inputs consistently. The existing IDs are registered to the maintainer's team.
The source supports compiling the preview without those profiles.

## Notarization and release export

Use the signed app printed by the builder and an authorized Apple Developer account
configured in Xcode. This uploads the compiled app and embedded extension to Apple.

```sh
python3 scripts/notarize-connection-manager.py --app /absolute/path/ConnectionManager.app
```

The wrapper prints its archive and export paths. `--prepare-only` prepares an archive
locally. After Apple accepts the submission, retrieve the notarized distribution using
the archive path printed by the wrapper.

```sh
xcodebuild -exportNotarizedApp \
  -archivePath /absolute/path/ConnectionManager.xcarchive \
  -exportPath /absolute/path/notarized-export
codesign --verify --deep --strict /absolute/path/notarized-export/ConnectionManager.app
xcrun stapler validate /absolute/path/notarized-export/ConnectionManager.app
spctl --assess --type execute --verbose=4 /absolute/path/notarized-export/ConnectionManager.app
ditto -c -k --sequesterRsrc --keepParent \
  /absolute/path/notarized-export/ConnectionManager.app ConnectionManager.zip
```

Share the ZIP containing the retrieved app. Test fresh installation and approval on a
second Mac. A passing signature check does not establish VPN compatibility or routing behavior.

The optional installer sets up one persistent controller and preserves existing settings.
It computes the current user's paths and rewrites the launch-agent template.

```sh
python3 scripts/install-local.py --signed-app /absolute/path/notarized-export/ConnectionManager.app
```

The installer requires one discoverable native IPSec profile before replacement and
starts the ordinary controller. Saved armed intent can reconnect that VPN. For UI work,
use the preview. The historical `archive-installation.sh` helper contains maintainer-specific
paths and is retained for source completeness.

## Contributor-to-maintainer workflow

1. Fork the repository, make the focused fix, and report the source commit and test results.
2. The maintainer reviews and builds that source on their Mac, including the router extension.
3. The maintainer signs both bundles with their Developer ID and matching profiles,
   submits the build to Apple for notarization, retrieves it and returns the ZIP.
4. The contributor checks installation, native approvals and the original failure on their Mac.

A supplied archive or app can be useful for diagnosis, but notarization does not replace
development signatures or grant missing entitlements. Turning a contributor-signed binary
into a maintainer release requires re-signing and matching provisioning for the entire
bundle before notarization. Source changes provide a reproducible handoff. Signing private
keys and Apple account credentials stay with the signer.

## Xcode App Store project

`ConnectionManager.xcodeproj` retains the latest store candidate and the `APP_STORE`
compile condition. It uses App Store entitlement variants and a separate lifecycle.
Select an appropriate team in Xcode for your own fork. The Python Developer ID builder
and the Xcode App Store export route have different signing settings.
The user reports rejection of the App Store submission under individual enrollment.

## Diagnosing VPN unknown

`VPNService.serviceID()` selects one enabled service whose interface type equals
`kSCNetworkInterfaceTypeIPSec` in the active network location. Zero or multiple matches
return nil, which becomes unknown. Signing or notarization does not change that discovery.
For a report, include processor type, macOS version, app/source version, exact error,
VPN protocol and whether it is a system profile or vendor-managed client. Redact local
service IDs, endpoints, usernames and credentials. Debug this on the affected Mac.

## Apple references

- [Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Provisioning profiles and macOS entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [System-extension signing and notarization](https://developer.apple.com/documentation/systemextensions)
- [Developer ID certificate and profile expiration](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
