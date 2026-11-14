#!/usr/bin/env python3
"""Install the controller/UI while preserving connection intent.

This installer does not activate network extensions or change the VPN profile.
It prepares and verifies the replacement before recoverably moving old files.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
USER_HOME = Path.home()
APP = USER_HOME / 'Applications/ConnectionManager.app'
LEGACY_APP = USER_HOME / 'Applications/Cambridge VPN Auto.app'
AGENT = USER_HOME / 'Library/LaunchAgents/com.wjli.cambridge-vpn-auto.plist'
SERVICE = f'gui/{os.getuid()}/com.wjli.cambridge-vpn-auto'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def bootstrap_agent():
    # bootout and macOS background-item registration settle asynchronously.
    # Retry only the observed transient EIO instead of treating it as success.
    last = None
    for delay in (0, 0.5, 1, 2, 3, 5):
        if delay:
            time.sleep(delay)
        last = subprocess.run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(AGENT)],
                              capture_output=True, text=True)
        if last.returncode == 0:
            return
        if last.returncode != 5:
            break
    raise RuntimeError('LaunchAgent bootstrap failed: ' + (last.stderr.strip() if last else 'no result'))


def inventory(path):
    files = sorted(path.rglob('*')) if path.is_dir() else [path]
    result = {}
    for item in files:
        key = str(item.relative_to(path)) if path.is_dir() else item.name
        if item.is_symlink():
            result[key] = {'symlink': os.readlink(item)}
        elif item.is_file():
            result[key] = {'bytes': item.stat().st_size, 'sha256': hashlib.sha256(item.read_bytes()).hexdigest()}
    return result


def main():
    global APP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signed-app', type=Path, help='Install an already signed bundle into /Applications')
    parser.add_argument('--safari-test-mode', action='store_true', help='Launch the signed controller with Safari-only test controls')
    args = parser.parse_args()
    user_app = APP
    if args.safari_test_mode and not args.signed_app:
        parser.error('--safari-test-mode requires --signed-app')
    if args.signed_app:
        APP = Path('/Applications/ConnectionManager.app')
    if not args.signed_app and any((app / 'Contents/Library/SystemExtensions').exists() for app in (APP, LEGACY_APP, Path('/Applications/ConnectionManager.app'))):
        raise RuntimeError('The installed app contains network extensions. Use the signed deployment procedure; this installer will not downgrade it.')
    (ROOT / '.build').mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='controller-install-', suffix='.noindex', dir=ROOT / '.build'))
    staged_app = stage / APP.name
    if args.signed_app:
        source = args.signed_app.resolve()
        extension = source / 'Contents/Library/SystemExtensions/com.wjli.cambridge-vpn-auto.connection-router.systemextension'
        if not extension.is_dir():
            raise RuntimeError('Signed bundle is missing the connection-router extension')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', source)
        signature = run('/usr/bin/codesign', '-dvv', source, capture_output=True, text=True).stderr
        if 'Authority=Developer ID Application:' not in signature:
            raise RuntimeError('Signed deployment requires Developer ID Application signing')
        shutil.copytree(source, staged_app, symlinks=True)
    else:
        run('/usr/bin/swift', 'build', '--package-path', ROOT, '-c', 'release', '--product', 'CambridgeVPNAuto')
        binary_dir = Path(run('/usr/bin/swift', 'build', '--package-path', ROOT, '-c', 'release', '--show-bin-path', capture_output=True, text=True).stdout.strip())
        (staged_app / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(binary_dir / 'CambridgeVPNAuto', staged_app / 'Contents/MacOS/CambridgeVPNAuto')
        shutil.copy2(ROOT / 'Resources/Info.plist', staged_app / 'Contents/Info.plist')
        (staged_app / 'Contents/Resources').mkdir()
        shutil.copy2(ROOT / 'Resources/ConnectionManager.icns', staged_app / 'Contents/Resources/ConnectionManager.icns')
        run('/usr/bin/codesign', '--sign', '-', '--timestamp=none', staged_app)
    run('/usr/bin/plutil', '-lint', staged_app / 'Contents/Info.plist')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', staged_app)
    # Query the candidate's provider-neutral discovery before replacing anything.
    run(staged_app / 'Contents/MacOS/CambridgeVPNAuto', '--vpn-service')
    launch_info = plistlib.loads((ROOT / 'Resources/com.wjli.cambridge-vpn-auto.plist').read_bytes())
    launch_info['ProgramArguments'][0] = str(APP / 'Contents/MacOS/CambridgeVPNAuto')
    if args.safari_test_mode:
        launch_info['ProgramArguments'] = [launch_info['ProgramArguments'][0], '--safari-test-mode']
    logs = USER_HOME / 'Library/Logs/CambridgeVPNAuto'
    launch_info['StandardOutPath'] = str(logs / 'agent.log')
    launch_info['StandardErrorPath'] = str(logs / 'agent-error.log')
    staged_agent = stage / AGENT.name
    staged_agent.write_bytes(plistlib.dumps(launch_info))
    run('/usr/bin/plutil', '-lint', staged_agent)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    archive = USER_HOME / 'Workspace/discarded/CambridgeVPNAuto' / ('install-' + stamp + '.noindex')
    archive.mkdir(parents=True, exist_ok=False)
    previous = list(dict.fromkeys(path for path in (APP, user_app, LEGACY_APP, AGENT) if path.exists()))
    mappings = []
    for path in previous:
        if path.stat().st_dev != archive.stat().st_dev:
            raise RuntimeError('Archive must be on the source filesystem; source retained')
        mappings.append({'source': str(path), 'destination': str(archive / path.relative_to('/')), 'inventory': inventory(path)})
    (archive / 'mapping.json').write_text(json.dumps(mappings, indent=2) + '\n')
    (archive / 'README.md').write_text('# Previous ConnectionManager installation\n\n'
        'Recoverable same-filesystem moves; nothing deleted. Zero bytes or inodes reclaimed.\n'
        'Source paths, destinations and checksums are in mapping.json.\n'
        'Persistent control-state.json and app-routing.json remain in Application Support.\n'
        'To restore, unload the current LaunchAgent, move the current installation into a new top-level discard bucket, '
        'then move these archived paths to their recorded source paths and bootstrap the restored LaunchAgent. '
        'Do not run two controllers. The VPN itself need not be disconnected.\n')
    # A successful bootout stops the controller only, not the system VPN service.
    result = subprocess.run(['/bin/launchctl', 'bootout', SERVICE], capture_output=True, text=True)
    if result.returncode != 0:
        still_loaded = subprocess.run(['/bin/launchctl', 'print', SERVICE], capture_output=True).returncode == 0
        if still_loaded:
            raise RuntimeError('Could not unload the existing controller; installation retained')
    moved = []
    installed = []
    try:
        for item in mappings:
            source, destination = Path(item['source']), Path(item['destination'])
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source.suffix == '.app':
                subprocess.run([LSREGISTER, '-u', str(source)], capture_output=True)
            source.rename(destination)
            moved.append((source, destination))
            if inventory(destination) != item['inventory']:
                raise RuntimeError('Archive verification failed: ' + str(destination))
        APP.parent.mkdir(parents=True, exist_ok=True)
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        logs.mkdir(parents=True, exist_ok=True)
        staged_app.rename(APP)
        installed.append(APP)
        staged_agent.rename(AGENT)
        installed.append(AGENT)
        bootstrap_agent()
        time.sleep(2)
        run('/bin/launchctl', 'print', SERVICE, stdout=subprocess.DEVNULL)
        run(APP / 'Contents/MacOS/CambridgeVPNAuto', '--status')
    except Exception:
        subprocess.run(['/bin/launchctl', 'bootout', SERVICE], capture_output=True)
        for path in installed:
            if path.exists():
                failed = archive / 'failed-replacement' / path.relative_to('/')
                failed.parent.mkdir(parents=True, exist_ok=True)
                path.rename(failed)
        for source, destination in reversed(moved):
            destination.rename(source)
        (archive / 'outcome.json').write_text(json.dumps({
            'outcome': 'rolled_back', 'originals_restored': True,
            'failed_replacement_retained': bool(installed),
        }, indent=2) + '\n')
        with (archive / 'README.md').open('a') as record:
            record.write('\nInstallation rolled back. Original files returned to their source paths; '
                         'failed replacement files, if any, remain under failed-replacement/.\n')
        if AGENT.exists():
            bootstrap_agent()
        raise
    run(LSREGISTER, '-f', APP)
    print('INSTALLED=' + str(APP))
    print('ARCHIVE=' + str(archive))
    print('Connection intent preserved. Extension activation remains a separate explicit step.' if args.signed_app else
          'Connection intent preserved. App rules are saved only; this unsigned installation does not enforce them.')


if __name__ == '__main__':
    main()
