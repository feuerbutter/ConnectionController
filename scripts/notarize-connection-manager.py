#!/usr/bin/env python3
"""Submit a signed SwiftPM ConnectionManager bundle through Xcode notarization.

Uses the Apple account already configured in Xcode. Keys and profiles are not
exported. The prepared archive and Xcode export logs remain under .build/.
"""
import argparse
import datetime
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--prepare-only', action='store_true', help='Prepare the local archive and export options without uploading')
    args = parser.parse_args()
    app = args.app.resolve()
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    bundles = [app] + list((app / 'Contents/Library/SystemExtensions').glob('*.systemextension'))
    profiles = {}
    teams = set()
    for bundle in bundles:
        data = run('/usr/bin/security', 'cms', '-D', '-i', bundle / 'Contents/embedded.provisionprofile', capture_output=True).stdout
        profile = plistlib.loads(data)
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        profiles[info['CFBundleIdentifier']] = profile['UUID']
        teams.add(profile['TeamIdentifier'][0])
    if len(teams) != 1 or len(bundles) != 2:
        raise RuntimeError('Expected one host and one router under the same team')
    team = teams.pop()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    stage = Path(tempfile.mkdtemp(prefix='notarization-', suffix='.noindex', dir=ROOT / '.build'))
    archive = stage / 'ConnectionManager.xcarchive'
    product = archive / 'Products/Applications' / app.name
    product.parent.mkdir(parents=True)
    shutil.copytree(app, product, symlinks=True)
    archive_info = {
        'ArchiveVersion': 2,
        'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        'Name': 'ConnectionManager', 'SchemeName': 'ConnectionManager',
        'ApplicationProperties': {
            'ApplicationPath': 'Applications/' + app.name,
            'CFBundleIdentifier': info['CFBundleIdentifier'],
            'CFBundleShortVersionString': info['CFBundleShortVersionString'],
            'CFBundleVersion': info['CFBundleVersion'],
            'SigningIdentity': 'Developer ID Application', 'Team': team,
            'Architectures': ['arm64'],
        },
    }
    (archive / 'Info.plist').write_bytes(plistlib.dumps(archive_info))
    options = stage / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps({
        'method': 'developer-id', 'destination': 'upload', 'teamID': team,
        'signingStyle': 'manual', 'signingCertificate': 'Developer ID Application',
        'provisioningProfiles': profiles,
    }))
    print('ARCHIVE=' + str(archive), flush=True)
    print('EXPORT=' + str(stage / 'export'), flush=True)
    if args.prepare_only:
        print('LOCAL PREPARATION ONLY: no upload was performed.')
        return
    run('/usr/bin/xcodebuild', '-exportArchive', '-archivePath', archive,
        '-exportPath', stage / 'export', '-exportOptionsPlist', options,
        '-allowProvisioningUpdates')
    print('Submission completed. Retrieve the notarized distribution before activation:')
    print('xcodebuild -exportNotarizedApp -archivePath ' + str(archive) + ' -exportPath ' + str(stage / 'notarized-export'))
    print('Validate the RETRIEVED app with stapler and spctl; the original archive product may have a different signature.')


if __name__ == '__main__':
    main()
