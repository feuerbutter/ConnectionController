#!/bin/zsh

set -euo pipefail

app_bundle="/Users/wjli/Applications/ConnectionManager.app"
launch_agent="/Users/wjli/Library/LaunchAgents/com.wjli.cambridge-vpn-auto.plist"
state_file="/Users/wjli/Library/Application Support/CambridgeVPNAuto/control-state.json"
log_directory="/Users/wjli/Library/Logs/CambridgeVPNAuto"
uid_value=$(/usr/bin/id -u)
timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
archive_root="/Users/wjli/Workspace/discarded/CambridgeVPNAuto/uninstalled-$timestamp"

/bin/launchctl bootout "gui/$uid_value" "$launch_agent" 2>/dev/null || true
/bin/mkdir -p "$archive_root"

if [[ -e "$app_bundle" ]]; then
    /bin/mv "$app_bundle" "$archive_root/ConnectionManager.app"
fi
if [[ -e "$launch_agent" ]]; then
    /bin/mv "$launch_agent" "$archive_root/com.wjli.cambridge-vpn-auto.plist"
fi
if [[ -e "$state_file" ]]; then
    /bin/mv "$state_file" "$archive_root/control-state.json"
fi
if [[ -d "$log_directory" ]]; then
    /bin/mv "$log_directory" "$archive_root/logs"
fi

echo "Controller files archived at $archive_root"
echo "The current VPN connection was not stopped."
