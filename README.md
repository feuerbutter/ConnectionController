# ConnectionController

A native macOS app for per-app Direct, VPN-only and Block rules, with automatic recovery
of one existing native IPSec VPN connection. The direct-distribution app is named
**ConnectionManager**. This repository was previously named **StayConnected**.

The current application code, routing extension and tests are published together.
[Source provenance](docs/source-provenance.md) records the imported revision and compatibility names.

## Requirements

- macOS 13 or later, Xcode with its macOS SDK, and Swift 5.9 or newer.
- Python 3 for the packaging and installation scripts.
- One enabled native **IPSec** VPN profile in the current macOS network location for
  VPN discovery, reconnect and the current Apply workflow.

VPN discovery requires exactly one matching profile. With zero or multiple matches it
returns unknown. A connected vendor VPN client can therefore coexist with a VPN unknown
message in this app. The code uses SystemConfiguration's native IPSec interface type.
Compatibility with other VPN types needs implementation and live testing. The older
StayConnected multi-provider selector remains in Git history.

## Build and inspect

```sh
git clone https://github.com/feuerbutter/ConnectionController.git
cd ConnectionController
swift run CambridgeVPNAutoCoreChecks
swift build -c release
python3 scripts/build-connection-manager.py --preview
```

The preview builder prints `BUILD=` with the generated application path. Open that app
to inspect the UI. It is isolated from saved rules and the VPN controller. Routing
activation requires the signed distribution workflow below. SwiftPM builds for the
local Mac's architecture by default. The previously shared 2.1.2 app was arm64-only.

Read-only command-line diagnostics are available after building.

```sh
swift run CambridgeVPNAuto --help
swift run CambridgeVPNAuto --vpn-service
swift run CambridgeVPNAuto --status
```

The service command exits with code 3 when discovery finds no unique supported profile.
It can print a private local service ID. Redact that ID before posting diagnostics.

## Signing and installation

An end user can install a Developer ID–signed, notarized release without an Apple
Developer membership. That release has no weekly reinstall requirement. The developer's
embedded provisioning profiles must remain valid.

Local core checks and UI preview work without paid signing. Per-app routing uses restricted
Network Extension and system-extension entitlements, so full activation requires matching
signatures and provisioning for the host and router. The current Python packager accepts
Developer ID signing. A free Xcode Personal Team does not provide this deployment path.

[Build, signing, notarization and installation instructions](docs/build-and-signing.md)
describe both maintainer-signed releases and contribution from another Mac.

## Behavior and coverage

Choose an app in Application Connections, select its route, and apply the saved policy
after macOS approves the signed extension and network configurations. New installations
start with no app rules. Explicit rules apply to their selected identities, while unlisted
apps follow existing macOS routing. Shared configured DNS follows macOS, including during Block.

The reconnect controller persists manual pause and retries unexpected drops with backoff.
Use its Off control when you intend to stay disconnected. An ordinary controller launch
can reconnect an existing supported VPN when armed.

The current code has been exercised on the maintainer's Mac with Safari Direct, VPN-only,
Block and recovery. Other VPNs and machines need independent validation. Provider-crash
containment, every helper attribution case, IPv6-only networks and all sleep/network-change
cases have incomplete coverage. Use this implementation experimentally.

## Contribute

Fork the repository and send a focused pull request with the exact macOS version,
processor, observed error, VPN type and the checks performed. For VPN unknown, start with
`Sources/CambridgeVPNAuto/VPNService.swift` and `Sources/ConnectionRouter/NetworkState.swift`.
Keep VPN server details, credentials, profiles and local state out of the report.

The maintainer can review your source changes, build the host and extension, sign both
with their Developer ID, notarize the result and return the distribution ZIP. A binary
signed with a different development identity needs the corresponding signing/provisioning
work before it can become a maintainer-signed release.

See [CONTRIBUTING.md](CONTRIBUTING.md), [CHANGELOG.md](CHANGELOG.md) and [LICENSE](LICENSE).
