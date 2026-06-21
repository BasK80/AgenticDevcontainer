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

{
    printf 'LOCAL_WORKSPACE_FOLDER_BASENAME=%s\n' "$PROJECT"
    printf 'TZ=%s\n' "${_tz:-UTC}"
    printf 'HOST_GITCONFIG=%s%s/.gitconfig\n' "${USERPROFILE:-}" "${HOME}"
    emit_if_set CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}"
    emit_if_set ANTHROPIC_API_KEY       "${ANTHROPIC_API_KEY:-}"
    emit_if_set ANTHROPIC_BASE_URL      "${ANTHROPIC_BASE_URL:-}"
} > .env
