#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
exec /usr/bin/python3 "$project_root/scripts/install-local.py"
