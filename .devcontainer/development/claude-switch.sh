# claude-switch.sh — switch Claude Code between Azure AI Foundry, a direct
# Anthropic API key, or the Anthropic OAuth flow (Claude subscription).
#
# Sourced from ~/.zshrc by post-create.sh. Defines four commands:
#   use-anthropic-key  route Claude through the Anthropic API using an API key
#                      (ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL) — DEFAULT
#   use-foundry        route Claude through Azure AI Foundry
#   use-anthropic      route Claude through the Anthropic OAuth login flow
#                      (Claude subscription)
#   claude-mode        show the currently active provider
#
# All `use-*` commands rewrite ~/.claude/settings.json AND export/unset
# the relevant environment variables in the current shell so the next
# `claude` invocation picks them up.

# Defaults — override by exporting these before sourcing this file.
: "${ANTHROPIC_FOUNDRY_RESOURCE:=mowiwo-workshop-agentic-resource}"
: "${ANTHROPIC_DEFAULT_SONNET_MODEL:=claude-sonnet-4-6}"
: "${ANTHROPIC_DEFAULT_OPUS_MODEL:=claude-opus-4-6}"
: "${ANTHROPIC_DEFAULT_HAIKU_MODEL:=claude-haiku-4-5}"
: "${ANTHROPIC_BASE_URL:=https://api.anthropic.com}"
# ANTHROPIC_API_KEY has no default — must be exported by the caller
# (typically passed into the devcontainer via .env / initializeCommand).

_CLAUDE_SETTINGS="$HOME/.claude/settings.json"

_claude_write_settings() {
    # $1 = "foundry" | "anthropic-key" | "anthropic"
    # Merges only the "env" key so that user-set fields (model, theme,
    # allowedPaths, etc.) survive provider switches.
    mkdir -p "$(dirname "$_CLAUDE_SETTINGS")"

    local new_env
    case "$1" in
    foundry)
        new_env=$(jq -n \
            --arg resource "${ANTHROPIC_FOUNDRY_RESOURCE}" \
            --arg sonnet   "${ANTHROPIC_DEFAULT_SONNET_MODEL}" \
            --arg opus     "${ANTHROPIC_DEFAULT_OPUS_MODEL}" \
            --arg haiku    "${ANTHROPIC_DEFAULT_HAIKU_MODEL}" \
            '{"CLAUDE_CODE_USE_FOUNDRY":"1",
              "ANTHROPIC_FOUNDRY_RESOURCE":$resource,
              "ANTHROPIC_DEFAULT_SONNET_MODEL":$sonnet,
              "ANTHROPIC_DEFAULT_OPUS_MODEL":$opus,
              "ANTHROPIC_DEFAULT_HAIKU_MODEL":$haiku}')
        ;;
    anthropic-key)
        new_env=$(jq -n \
            --arg key  "${ANTHROPIC_API_KEY:-}" \
            --arg base "${ANTHROPIC_BASE_URL}" \
            '{"ANTHROPIC_API_KEY":$key,"ANTHROPIC_BASE_URL":$base}')
        ;;
    *)
        new_env='{}'
        ;;
    esac

    if [[ -f "$_CLAUDE_SETTINGS" ]]; then
        jq --argjson e "$new_env" '.env = $e' "$_CLAUDE_SETTINGS" \
            > "${_CLAUDE_SETTINGS}.tmp" \
            && mv "${_CLAUDE_SETTINGS}.tmp" "$_CLAUDE_SETTINGS"
    else
        jq -n --argjson e "$new_env" '{"env": $e}' > "$_CLAUDE_SETTINGS"
    fi
}

use-foundry() {
    export CLAUDE_CODE_USE_FOUNDRY=1
    export ANTHROPIC_FOUNDRY_RESOURCE
    export ANTHROPIC_DEFAULT_SONNET_MODEL
    export ANTHROPIC_DEFAULT_OPUS_MODEL
    export ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_BASE_URL
    _claude_write_settings foundry
    echo "[claude] provider: Azure AI Foundry  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE})"
    if ! az account show >/dev/null 2>&1; then
        echo "[claude] not logged in to Azure — run: az login"
    fi
}

use-anthropic-key() {
    unset CLAUDE_CODE_USE_FOUNDRY
    unset ANTHROPIC_FOUNDRY_RESOURCE
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    export ANTHROPIC_BASE_URL
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "[claude] WARNING: ANTHROPIC_API_KEY is not set — export it before running claude"
    else
        export ANTHROPIC_API_KEY
    fi
    _claude_write_settings anthropic-key
    echo "[claude] provider: Anthropic API key  (base: ${ANTHROPIC_BASE_URL})"
}

use-anthropic() {
    unset CLAUDE_CODE_USE_FOUNDRY
    unset ANTHROPIC_FOUNDRY_RESOURCE
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_BASE_URL
    _claude_write_settings anthropic
    echo "[claude] provider: Anthropic OAuth (Claude subscription)"
    # Only auto-launch the interactive login when running in a TTY; in
    # non-interactive contexts (e.g. devcontainer postCreateCommand) it
    # would exit non-zero and abort the caller under `set -e`.
    if [ -t 0 ] && [ -t 1 ]; then
        if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -s "$HOME/.claude.json" ]; then
            echo "[claude] launching: claude login"
            claude login
        fi
    else
        echo "[claude] not in a TTY — run: claude login"
    fi
}

# Convenience aliases.
alias use-claude=use-anthropic-key
alias use-azure=use-foundry

claude-mode() {
    if [ "${CLAUDE_CODE_USE_FOUNDRY:-0}" = "1" ]; then
        echo "Azure AI Foundry  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE:-<unset>})"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ] || grep -q '"ANTHROPIC_API_KEY"' "$_CLAUDE_SETTINGS" 2>/dev/null; then
        echo "Anthropic API key  (base: ${ANTHROPIC_BASE_URL:-https://api.anthropic.com})"
    else
        echo "Anthropic OAuth (Claude subscription)"
    fi
}
