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

# ── Azure CLI browser login flow ──────────────────────────────────────────
# Ensure the browser callback login flow is active when Foundry is enabled.
# post-create.sh used to own this; post-start.sh runs on every start so it
# is the correct owner (az config is not persisted across rebuilds).
if [[ "${CLAUDE_CODE_USE_FOUNDRY:-0}" == "1" ]]; then
    az config set core.login_experience_v2=on 2>/dev/null || true
    echo "[setup] Azure CLI browser login flow enabled for Foundry"
fi


# ── Restore the active LLM provider on every start ───────────────────────
# post-create.sh only runs on first creation; settings.json lives on a named
# volume that a full rebuild can wipe. Re-apply the persisted provider choice
# (~/.llm-provider, written by the use-* commands) so a deliberate switch —
# e.g. to OAuth — survives rebuilds instead of snapping back to API-key mode.
# shellcheck disable=SC1090
source /workspace/.devcontainer/development/llm-switch.sh
if [[ -f "$HOME/.llm-provider" ]]; then
    _llm_apply_persisted
    echo "[setup] Restored provider: $(< "$HOME/.llm-provider")"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]] && [[ "${CLAUDE_CODE_USE_FOUNDRY:-0}" != "1" ]]; then
    # No choice recorded yet, but a key is available — default to API-key mode.
    use-anthropic-key >/dev/null
    echo "[setup] Defaulted provider: Anthropic API key"
fi

echo "[post-start] done."
