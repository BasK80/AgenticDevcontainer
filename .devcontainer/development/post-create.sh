#!/usr/bin/env bash
# post-create.sh — runs ONCE after the container is first created.
# Safe to re-run: all writes are guarded with existence checks.
# Add project-specific setup below (npm ci, uv sync, etc.).
set -euo pipefail

# ── Project dependency install ────────────────────────────────────────────
# Uncomment whichever applies to your project.

# if [[ -f package.json ]]; then
#     echo "[setup] npm ci"
#     npm ci || npm install
# fi

# if [[ -f requirements.txt ]]; then
#     echo "[setup] pip install"
#     pip install --user -r requirements.txt
# fi

# if [[ -f pyproject.toml ]] && command -v uv &>/dev/null; then
#     echo "[setup] uv sync"
#     uv sync
# fi

# ── Claude provider switcher ──────────────────────────────────────────────
# Install `use-anthropic-key` / `use-foundry` / `use-anthropic` / `llm-mode`
# shell commands.
SWITCH_SRC="/workspace/.devcontainer/development/llm-switch.sh"
ZSHRC="$HOME/.zshrc"
if [[ -f "$SWITCH_SRC" ]] && ! grep -q "llm-switch.sh" "$ZSHRC" 2>/dev/null; then
    echo "[ -f $SWITCH_SRC ] && source $SWITCH_SRC" >> "$ZSHRC"
    echo "[setup] Registered llm-switch.sh in ~/.zshrc"
fi

# Pick a default provider on first creation:
#   - Foundry if CLAUDE_CODE_USE_FOUNDRY=1 (explicit opt-in)
#   - Claude on an Anthropic subscription (use-anthropic, OAuth) otherwise — the
#     default. A static ANTHROPIC_API_KEY no longer auto-selects key mode; run
#     `use-anthropic-key` to opt in. See README "Choosing a provider".
SETTINGS="$HOME/.claude/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
    # shellcheck disable=SC1090
    source "$SWITCH_SRC"
    if [[ "${CLAUDE_CODE_USE_FOUNDRY:-0}" == "1" ]]; then
        use-foundry >/dev/null
        echo "[setup] Default provider: Azure AI Foundry"
    else
        use-anthropic >/dev/null
        echo "[setup] Default provider: Claude (Anthropic subscription, OAuth)"
    fi
else
    echo "[setup] $SETTINGS already exists — leaving provider settings as-is"
fi

# Ensure /workspace is trusted — idempotent, safe to run on every start.
jq --arg p /workspace \
   '.allowedPaths = ((.allowedPaths // []) + [$p] | unique)' \
   "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
echo "[setup] /workspace added to Claude allowedPaths"

echo "[post-create] done."
