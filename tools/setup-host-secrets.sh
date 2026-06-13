#!/usr/bin/env bash
# setup-host-secrets.sh — run once on the WSL2 host to store API credentials
# that initialize.sh will pick up on every devcontainer rebuild.
#
# Usage:
#   bash tools/setup-host-secrets.sh
#
# Secrets stored in: ~/.devcontainer-secrets (never committed, gitignored)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS_FILE="$HOME/.devcontainer-secrets"
INIT_SCRIPT="$SCRIPT_DIR/../.devcontainer/initialize.sh"
PATCH_MARKER="devcontainer-secrets"

# ── Patch initialize.sh to source the secrets file ───────────────────────
if ! grep -q "$PATCH_MARKER" "$INIT_SCRIPT"; then
    TMPFILE="$(mktemp)"
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ "$line" =~ ^PROJECT= ]]; then
            printf '\n'
            printf '# Load secrets stored by setup-host-secrets.sh (survives rebuilds, never committed). # %s\n' "$PATCH_MARKER"
            printf 'if [[ -f "$HOME/.devcontainer-secrets" ]]; then\n'
            printf '    # shellcheck disable=SC1090\n'
            printf '    source "$HOME/.devcontainer-secrets"\n'
            printf 'fi\n'
        fi
    done < "$INIT_SCRIPT" > "$TMPFILE"
    mv "$TMPFILE" "$INIT_SCRIPT"
    chmod +x "$INIT_SCRIPT"
    printf 'Patched %s to source ~/.devcontainer-secrets\n' "$INIT_SCRIPT"
else
    printf '%s already patched — skipping.\n' "$INIT_SCRIPT"
fi

# ── Collect secrets ───────────────────────────────────────────────────────
read_secret() {
    local prompt="$1"
    local current="$2"
    local value

    printf '%s\n' "$prompt" >&2
    if [[ -n "$current" ]]; then
        printf '  [currently set — leave blank to keep]: ' >&2
    else
        printf '  [leave blank to skip]: ' >&2
    fi
    read -rs value
    printf '\n' >&2

    if [[ -z "$value" ]]; then
        printf '%s' "$current"
    else
        printf '%s' "$value"
    fi
}

# Load existing values so re-running the script preserves unmodified keys.
current_api_key=""
current_base_url=""
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    current_api_key="${ANTHROPIC_API_KEY:-}"
    current_base_url="${ANTHROPIC_BASE_URL:-}"
fi

printf '\nDevcontainer secrets setup\n'
printf '══════════════════════════\n'

new_api_key="$(read_secret "ANTHROPIC_API_KEY — your Anthropic API key (console.anthropic.com → API keys)" "$current_api_key")"
new_base_url="$(read_secret "ANTHROPIC_BASE_URL — custom API endpoint, e.g. for a proxy (optional)" "$current_base_url")"

# ── Write secrets file ────────────────────────────────────────────────────
{
    printf '# Written by setup-host-secrets.sh — do not commit.\n'
    [[ -n "$new_api_key"  ]] && printf 'export ANTHROPIC_API_KEY=%s\n'  "$new_api_key"
    [[ -n "$new_base_url" ]] && printf 'export ANTHROPIC_BASE_URL=%s\n' "$new_base_url"
} > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

printf '\nSaved to %s\n' "$SECRETS_FILE"
printf 'Rebuild the devcontainer in VS Code to apply.\n'
