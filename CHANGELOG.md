# Changelog

## Source update — 14 November 2026

- Renamed the GitHub repository to ConnectionController while retaining its public history.
- Imported the current ConnectionManager app, per-app router/filter, tests, resources,
  signing and installation scripts, and App Store Xcode variant.
- Documented native IPSec discovery, local preview, signing requirements, friend-to-maintainer
  contribution workflow, and diagnostics for VPN unknown.
- Updated macOS CI for the imported Swift package and existing core checks.


## 0.1.0

- Initial reusable macOS menu-bar controller.
- Persistent selection among enabled native VPN profiles using service IDs.
- Manual pause, bounded reconnect backoff, wake recovery, and command deadlines.
- Generic per-user installer and recoverable uninstall.
- Local-only settings, macOS CI with checkout v7, issue templates, and contribution guide.
