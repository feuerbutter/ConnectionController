# Source provenance

The repository was renamed from StayConnected to ConnectionController on 14 November 2026.
Its original public history remains available through `b6045f985f9950ca5303d2dbda3d398ed9792cb7`.

Application source, tests, resources, Xcode project and scripts were imported byte-for-byte
from maintained ConnectionController revision `b1616fa440dc4682fe15d26670a97091ef1c6c62`. All files under `Sources/`,
`Tests/`, `Resources/`, `scripts/`, and `ConnectionManager.xcodeproj/`, together with
`Package.swift`, match that snapshot. Public documentation and CI describe the current build.

The direct-distribution resource version is ConnectionManager 2.1.2 (12). The Xcode project
retains the ConnectionController 1.0 (15) App Store variant selected by `APP_STORE`.
The user reports that App Review rejected the VPN-related submission under individual enrollment.
The current distribution workflow uses Developer ID signing and notarization.

Internal review correspondence, local deployment reports, settings, logs, build outputs,
provisioning profiles and private keys are excluded from this public import. Bundle identifiers,
target names and serialized compatibility keys retain their existing names.

Historical maintainer scripts and templates may contain the original maintainer's paths.
Use the documented Python installer, which computes the current user's paths and rewrites
the launch-agent template. `archive-installation.sh` is a historical maintainer-specific helper.
The old StayConnected implementation remains recoverable from the original public history.
Its multi-provider selector is not part of the imported current implementation.
