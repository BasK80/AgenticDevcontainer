#!/usr/bin/env bash
# apply-ping-wrapper.sh — run from the HOST to patch the read-only post-start.sh
# Usage:  bash apply-ping-wrapper.sh
set -euo pipefail

FILE=".devcontainer/development/post-start.sh"

if grep -q "ping-wrapper" "$FILE"; then
    echo "Already patched — nothing to do."
    exit 0
fi

# Insert the ping-wrapper install block before the final "done" echo.
sed -i 's|^echo "\[post-start\] done\."|# ── Install ping wrapper ──────────────────────────────────────────────────\n# ping bypasses the HTTP proxy and always fails in this container (no default\n# gateway on the internal network). Replace it with a script that explains\n# the situation and suggests curl as an alternative. ~/.local\/bin is first on\n# PATH (set in ~\/.zshrc) so it shadows \/usr\/bin\/ping without root access.\nmkdir -p "$HOME\/.local\/bin"\ncp \/workspace\/.devcontainer\/development\/ping-wrapper.sh "$HOME\/.local\/bin\/ping"\nchmod +x "$HOME\/.local\/bin\/ping"\necho "[setup] Installed ping wrapper in ~\/.local\/bin\/ping"\n\necho "[post-start] done."|' "$FILE"

echo "Patched $FILE — ping wrapper will be installed on next container start."
