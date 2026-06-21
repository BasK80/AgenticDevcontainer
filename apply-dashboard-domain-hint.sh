#!/usr/bin/env bash
# Run this script FROM THE HOST to patch the control dashboard.
# The file is read-only inside the dev container, so it must be edited on the host.
#
# What it does: inserts a small format-hint line below the add-domain input in
# the Active Allowlist card, explaining bare-domain vs. wildcard syntax.

set -euo pipefail

FILE="$(dirname "$0")/.devcontainer/control/dashboard.py"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found. Run this script from the repo root on the host." >&2
  exit 1
fi

python3 - "$FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

OLD = '            </div>\n            <div class="sub-label">Manual (permanent)</div>'
NEW = (
    '            </div>\n'
    '            <div style="font-size:11px;color:var(--muted);padding:2px 14px 6px">\n'
    '              <code>example.com</code> &mdash; exact host &nbsp;|&nbsp;'
    ' <code>.example.com</code> &mdash; all subdomains of example.com\n'
    '            </div>\n'
    '            <div class="sub-label">Manual (permanent)</div>'
)

if NEW in content:
    print("Patch already applied — nothing to do.")
    sys.exit(0)

if OLD not in content:
    print("ERROR: expected string not found in dashboard.py — the file may have changed upstream.")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content.replace(OLD, NEW, 1))

print(f"Patch applied to {path}")
print("Rebuild the control container to pick up the change:")
print("  docker compose -f .devcontainer/docker-compose.yml build control")
print("  docker compose -f .devcontainer/docker-compose.yml up -d")
PYEOF
