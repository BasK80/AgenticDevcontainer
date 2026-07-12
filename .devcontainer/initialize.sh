#!/usr/bin/env bash
# initialize.sh — runs on the HOST before docker-compose starts.
# Writes .devcontainer/.env with project-scoped names and OPTIONAL
# host env passthrough.
#
# Opt-in vars (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL)
# are only written when set on the host. Emitting them as empty (VAR=)
# would mask values persisted in the container's ~/.claude/settings.json,
# so we omit the line entirely instead.
set -eu

cd "$(dirname "$0")"

PROJECT="$(basename "$(cd .. && pwd)")"

# Load secrets stored by setup-host-secrets.sh (survives rebuilds, never committed). # devcontainer-secrets
if [[ -f "$HOME/.devcontainer-secrets" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.devcontainer-secrets"
fi

emit_if_set() {
    local name="$1"
    local val="$2"
    [ -n "$val" ] && printf '%s=%s\n' "$name" "$val"
    return 0
}

# Detect host timezone if TZ is not explicitly set
_tz="${TZ:-}"
if [[ -z "$_tz" ]]; then
    if [[ -f /etc/timezone ]]; then
        _tz=$(cat /etc/timezone)
    elif [[ -L /etc/localtime ]]; then
        _tz=$(readlink -f /etc/localtime | sed 's|.*/zoneinfo/||')
    fi
fi

# Derive a project-unique /24 for the internal network so multiple instances
# of this template can run concurrently without "Pool overlaps" errors.
# The firewall always sits at the .2 host of that subnet (used as DNS + proxy).
# Uses the roomy 10.0.0.0/8 space to avoid Docker's crowded 172.16/12 defaults.
_hash=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
_oct2=$(( _hash % 254 + 1 ))
_oct3=$(( (_hash / 254) % 256 ))
INTERNAL_SUBNET="10.${_oct2}.${_oct3}.0/24"
FIREWALL_IP="10.${_oct2}.${_oct3}.2"

# Derive per-project HOST ports from the same project hash so instances of
# differently-named folders can run in parallel (each publishes its own
# control-UI port and az-login callback range). Same-named folders collide
# here by design -> rename the folder to run a second instance.
#   CONTROL_PORT : firewall management web UI
#   DEV_PORT_*   : az login browser-callback window (slot 0 keeps 8400-8999
#                  so ADFS's fixed 8400 callback is preserved)
_slot=$(( _hash % 50 ))
CONTROL_PORT=$(( 8088 + _slot ))
DEV_PORT_BASE=$(( 8400 + _slot * 600 ))
DEV_PORT_END=$(( DEV_PORT_BASE + 599 ))

{
    printf 'LOCAL_WORKSPACE_FOLDER_BASENAME=%s\n' "$PROJECT"
    printf 'TZ=%s\n' "${_tz:-UTC}"
    printf 'INTERNAL_SUBNET=%s\n' "$INTERNAL_SUBNET"
    printf 'FIREWALL_IP=%s\n' "$FIREWALL_IP"
    printf 'CONTROL_PORT=%s\n' "$CONTROL_PORT"
    printf 'DEV_PORT_BASE=%s\n' "$DEV_PORT_BASE"
    printf 'DEV_PORT_END=%s\n' "$DEV_PORT_END"
    printf 'HOST_GITCONFIG=%s%s/.gitconfig\n' "${USERPROFILE:-}" "${HOME}"
    emit_if_set CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}"
    emit_if_set ANTHROPIC_API_KEY       "${ANTHROPIC_API_KEY:-}"
    emit_if_set ANTHROPIC_BASE_URL      "${ANTHROPIC_BASE_URL:-}"
} > .env
