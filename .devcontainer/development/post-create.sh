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
# Install `use-foundry` / `use-anthropic` / `claude-mode` shell commands.
SWITCH_SRC="/workspace/.devcontainer/development/claude-switch.sh"
ZSHRC="$HOME/.zshrc"
if [[ -f "$SWITCH_SRC" ]] && ! grep -q "claude-switch.sh" "$ZSHRC" 2>/dev/null; then
    echo "[ -f $SWITCH_SRC ] && source $SWITCH_SRC" >> "$ZSHRC"
    echo "[setup] Registered claude-switch.sh in ~/.zshrc"
fi

# Pick a default provider on first creation: Foundry if explicitly requested
# via CLAUDE_CODE_USE_FOUNDRY=1, otherwise the direct Anthropic API.
SETTINGS="$HOME/.claude/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
    # shellcheck disable=SC1090
    source "$SWITCH_SRC"
    if [[ "${CLAUDE_CODE_USE_FOUNDRY:-0}" == "1" ]]; then
        use-foundry >/dev/null
        echo "[setup] Default provider: Azure AI Foundry"
    else
        use-anthropic >/dev/null
        echo "[setup] Default provider: Anthropic direct API"
    fi
else
    echo "[setup] $SETTINGS already exists — leaving provider settings as-is"
fi

# Use browser callback login flow when Foundry mode is enabled.
if [[ "${CLAUDE_CODE_USE_FOUNDRY:-0}" == "1" ]]; then
  az config set core.login_experience_v2=on 2>/dev/null || true
  echo "[setup] Azure CLI browser login flow enabled for Foundry"
fi

echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  Switch Claude provider at any time:                     │"
echo "│    use-foundry      → Azure AI Foundry (run az login)    │"
echo "│    use-anthropic    → Anthropic direct API               │"
echo "│    claude-mode      → show active provider               │"
echo "└─────────────────────────────────────────────────────────┘"
# ─────────────────────────────────────────────────────────────────────────

echo "[post-create] done."
