#!/usr/bin/env python3
"""Build an inert preview, or package a Developer ID signed standalone guard."""
import argparse
import datetime
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.wjli.cambridge-vpn-auto'
EXT_ID = APP_ID + '.claude-guard'
CAPABILITY = 'app-proxy-provider-systemextension'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def load_profile(path, expected_id, host):
    data = run('/usr/bin/security', 'cms', '-D', '-i', str(path), capture_output=True).stdout
    profile = plistlib.loads(data)
    team = profile['TeamIdentifier'][0]
    grants = profile['Entitlements']
    app_key = 'com.apple.application-identifier'
    if app_key not in grants:
        app_key = 'application-identifier'
    if grants.get(app_key) != team + '.' + expected_id:
        raise ValueError('Profile does not authorize ' + expected_id)
    if CAPABILITY not in grants.get('com.apple.developer.networking.networkextension', []):
        raise ValueError('Profile lacks the app-proxy-provider-systemextension capability')
    expiry = profile.get('ExpirationDate')
    if expiry is None or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile is missing an expiry or has expired')
    entitlements = {
        app_key: grants[app_key],
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.networking.networkextension': [CAPABILITY],
    }
    if host:
        if not grants.get('com.apple.developer.system-extension.install'):
            raise ValueError('Host profile lacks system-extension.install')
        entitlements['com.apple.developer.system-extension.install'] = True
    else:
        entitlements.update({
            'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.network.server': True,
        })
    return team, entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preview', action='store_true', help='Ad-hoc signed, cannot activate network protection')
    mode.add_argument('--identity', help='Developer ID Application signing identity')
    parser.add_argument('--app-profile', type=Path)
    parser.add_argument('--extension-profile', type=Path)
    args = parser.parse_args()
    if args.identity:
        if not args.identity.startswith('Developer ID Application:'):
            parser.error('Use a Developer ID Application identity for direct distribution')
        if not args.app_profile or not args.extension_profile:
            parser.error('Both provisioning profiles are required for a signed build')
        team, app_entitlements = load_profile(args.app_profile, APP_ID, True)
        extension_team, extension_entitlements = load_profile(args.extension_profile, EXT_ID, False)
        if team != extension_team:
            parser.error('Host and extension profiles must belong to the same team')
    else:
        if args.app_profile or args.extension_profile:
            parser.error('Preview builds do not use provisioning profiles')
        team = 'UNSIGNED'

    run('/usr/bin/swift', 'build', '--package-path', str(ROOT), '-c', 'release')
    binary_dir = Path(run('/usr/bin/swift', 'build', '--package-path', str(ROOT), '-c', 'release',
                          '--show-bin-path', capture_output=True, text=True).stdout.strip())
    output = Path(tempfile.mkdtemp(prefix='claude-guard-preview-' if args.preview else 'claude-guard-signed-',
                                  dir=ROOT / '.build'))
    app = output / 'Cambridge VPN Auto.app'
    extension = app / 'Contents/Library/SystemExtensions' / (EXT_ID + '.systemextension')
    for bundle, binary, plist_path in [
        (app, 'CambridgeVPNAuto', ROOT / 'Resources/Info.plist'),
        (extension, 'ClaudeVPNGuard', ROOT / 'Resources/ClaudeGuard/Info.plist'),
    ]:
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(binary_dir / binary, bundle / 'Contents/MacOS' / binary)
        info = plistlib.loads(plist_path.read_bytes())
        if bundle == extension:
            info['NetworkExtension']['NEMachServiceName'] = team + '.' + EXT_ID
        else:
            info['CFBundleVersion'] = '2'
            info['CFBundleShortVersionString'] = '1.1.0'
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))

    if args.preview:
        # No restricted entitlements are asserted by the preview app.
        for bundle in (extension, app):
            run('/usr/bin/codesign', '--sign', '-', '--timestamp=none', str(bundle))
    else:
        for bundle, profile, entitlements, label in [
            (extension, args.extension_profile, extension_entitlements, 'extension'),
            (app, args.app_profile, app_entitlements, 'app'),
        ]:
            shutil.copy2(profile, bundle / 'Contents/embedded.provisionprofile')
            entitlement_path = output / (label + '.entitlements.plist')
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
            run('/usr/bin/codesign', '--sign', args.identity, '--options', 'runtime', '--timestamp',
                '--entitlements', str(entitlement_path), str(bundle))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    print('BUILD=' + str(app))
    if args.preview:
        print('INACTIVE PREVIEW: Claude is NOT protected. Do not treat this as an installed firewall.')
    else:
        print('SIGNED BUILD ONLY: notarization, macOS approval and live validation are still required.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
