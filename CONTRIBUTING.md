# Contributing

Use a focused branch and pull request. Describe the observed problem, changed behavior,
environment and validation. The application source retains compatibility identifiers
from earlier versions, including the CambridgeVPNAuto module names.

## Layout

- `Sources/CambridgeVPNAuto` contains the app UI, controller, VPN discovery and activation.
- `Sources/CambridgeVPNAutoCore` contains persistence, rules, identities and bounded commands.
- `Sources/ConnectionRouter` and `Sources/ConnectionRouterObjC` contain the transparent
  TCP/UDP router, system DNS handling, interface discovery and content filter.
- `Tests/CambridgeVPNAutoCoreTests` contains the existing framework-free checks.
- `Resources`, `scripts` and `ConnectionManager.xcodeproj` contain packaging and signing inputs.
- `Sources/ClaudeVPNGuard` is retained historical implementation.

## Development checks

```sh
swift run CambridgeVPNAutoCoreChecks
swift build -c release
python3 scripts/build-connection-manager.py --preview
zsh -n scripts/install.sh scripts/archive-installation.sh
```

The preview permits UI work without activating the router or modifying normal saved rules.
For VPN unknown, inspect `VPNService.serviceID()` first. It requires exactly one enabled
native IPSec service in the active network location. Tunnel lookup is in
`Sources/ConnectionRouter/NetworkState.swift`. Support for another provider may require
changes to both discovery and routing, with live evidence that the selected tunnel is used.

Record the exact source commit, Mac processor, macOS version, VPN type and affected flow
types. Distinguish compilation, UI inspection, extension activation and actual traffic
behavior in the report. Run live tests only on a connection you are authorized to change.

## Signing handoff

You can contribute source changes without owning distribution credentials. Submit your
branch or patch and the build/test results. The maintainer can build, sign and notarize
the reviewed code using the [distribution guide](docs/build-and-signing.md).

Keep signing keys, account credentials, provisioning profiles, local VPN service IDs,
VPN endpoints, settings, logs and private screenshots outside Git. Existing Team IDs and
bundle identifiers in build configuration are public identifiers. Use your own registered
identifiers and matching profiles if you independently sign a fork.
