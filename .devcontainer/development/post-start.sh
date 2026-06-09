#!/usr/bin/env bash
# post-start.sh — runs on every container start (including after rebuilds).
set -euo pipefail

# ── Persist ~/.claude.json across container rebuilds ─────────────────────
# ~/.claude.json lives in the container's filesystem layer and is lost on
# every rebuild. The ~/.claude/ directory is a named Docker volume and
# survives rebuilds, so we keep the real file there and symlink to it.
# This block runs before VS Code extensions (including Claude Code) start,
# so the symlink is always in place when Claude first reads the file.
CLAUDE_JSON_STORE="$HOME/.claude/.claude.json"
CLAUDE_JSON="$HOME/.claude.json"

if [ -f "$CLAUDE_JSON" ] && [ ! -L "$CLAUDE_JSON" ]; then
    # Real file exists (first run after this fix, or post-rebuild re-init).
    # Move it into the volume so future starts find it there.
    mv "$CLAUDE_JSON" "$CLAUDE_JSON_STORE"
    ln -sf "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
    echo "[setup] Migrated ~/.claude.json into persistent volume"
elif [ ! -e "$CLAUDE_JSON" ]; then
    if [ -f "$CLAUDE_JSON_STORE" ]; then
        # Normal post-rebuild path: store exists, just recreate the symlink.
        ln -sf "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
        echo "[setup] Restored ~/.claude.json symlink after rebuild"
    else
        # No store yet — check for backups left by the old layout.
        LATEST_BACKUP=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null \
                        | awk 'NR==1')
        if [ -n "$LATEST_BACKUP" ] && [ "$(wc -c < "$LATEST_BACKUP")" -gt 200 ]; then
            cp "$LATEST_BACKUP" "$CLAUDE_JSON_STORE"
            ln -sf "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
            echo "[setup] Seeded ~/.claude.json from backup: $(basename "$LATEST_BACKUP")"
        else
            printf '{}' > "$CLAUDE_JSON_STORE"
            ln -sf "$CLAUDE_JSON_STORE" "$CLAUDE_JSON"
            echo "[setup] Created empty ~/.claude.json in persistent volume"
        fi
    fi
fi
# else: already a symlink — nothing to do.

echo "[post-start] done."
