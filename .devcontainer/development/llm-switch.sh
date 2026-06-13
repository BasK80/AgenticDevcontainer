# claude-switch.sh — switch Claude Code (and opencode) between Azure AI Foundry,
# a direct Anthropic API key, or the Anthropic OAuth flow (Claude subscription).
#
# Sourced from ~/.zshrc by post-create.sh. Defines commands:
#   use-anthropic-key  route Claude through the Anthropic API using an API key
#                      (ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL) — DEFAULT
#                      opencode: ✅ fully configured automatically
#   use-foundry        route Claude through Azure AI Foundry
#                      opencode: ✅ configured via Azure provider — first time
#                                only, run '/connect' in opencode and enter
#                                the Azure API key; deployment name must match
#                                the model name
#   use-anthropic      route Claude through the Anthropic OAuth login flow
#                      (Claude subscription)
#                      opencode: ⚠️  run 'opencode providers login' separately
#   llm-mode           show the currently active Claude provider
#
# opencode reads its provider config from ~/.config/opencode/opencode.json.
# The use-anthropic-key and use-foundry functions keep this file in sync.
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
_OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

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

_opencode_write_config() {
    # $1 = "anthropic-key" | "azure" | "clear"
    # Merges only the "provider" key into ~/.config/opencode/opencode.json so
    # that user settings (model, theme, etc.) survive provider switches.
    mkdir -p "$(dirname "$_OPENCODE_CONFIG")"

    local new_provider
    case "$1" in
    anthropic-key)
        if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
            new_provider=$(jq -n \
                --arg key  "${ANTHROPIC_API_KEY:-}" \
                --arg base "${ANTHROPIC_BASE_URL}" \
                '{"anthropic":{"options":{"apiKey":$key,"baseURL":$base}}}')
        else
            new_provider=$(jq -n \
                --arg key "${ANTHROPIC_API_KEY:-}" \
                '{"anthropic":{"options":{"apiKey":$key}}}')
        fi
        ;;
    azure)
        # Resource name only — the API key must be stored once via '/connect'
        # inside opencode. Deployment name must match the model name.
        new_provider=$(jq -n \
            --arg res "${ANTHROPIC_FOUNDRY_RESOURCE}" \
            '{"azure":{"options":{"resourceName":$res}}}')
        ;;
    *)
        new_provider='{}'
        ;;
    esac

    if [[ -f "$_OPENCODE_CONFIG" ]]; then
        jq --argjson p "$new_provider" '.provider = $p' "$_OPENCODE_CONFIG" \
            > "${_OPENCODE_CONFIG}.tmp" \
            && mv "${_OPENCODE_CONFIG}.tmp" "$_OPENCODE_CONFIG"
    else
        jq -n \
            --argjson p "$new_provider" \
            '{"$schema":"https://opencode.ai/config.json","provider":$p}' \
            > "$_OPENCODE_CONFIG"
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
    # opencode: Azure provider via AZURE_RESOURCE_NAME (same resource).
    # The deployment name must match the model name in Azure AI Foundry.
    # First time only: run '/connect' inside opencode and enter the Azure API key.
    export AZURE_RESOURCE_NAME="${ANTHROPIC_FOUNDRY_RESOURCE}"
    _opencode_write_config azure
    echo "[opencode] provider: Azure  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE})"
    echo "[opencode] first-time auth: run '/connect' inside opencode → search Azure → enter API key"
}

use-anthropic-key() {
    unset CLAUDE_CODE_USE_FOUNDRY
    unset ANTHROPIC_FOUNDRY_RESOURCE
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset AZURE_RESOURCE_NAME
    export ANTHROPIC_BASE_URL
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "[claude] WARNING: ANTHROPIC_API_KEY is not set — export it before running claude"
    else
        export ANTHROPIC_API_KEY
    fi
    _claude_write_settings anthropic-key
    echo "[claude] provider: Anthropic API key  (base: ${ANTHROPIC_BASE_URL})"
    _opencode_write_config anthropic-key
    echo "[opencode] provider: Anthropic  (base: ${ANTHROPIC_BASE_URL:-https://api.anthropic.com})"
}

use-anthropic() {
    unset CLAUDE_CODE_USE_FOUNDRY
    unset ANTHROPIC_FOUNDRY_RESOURCE
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_BASE_URL
    unset AZURE_RESOURCE_NAME
    _claude_write_settings anthropic
    echo "[claude] provider: Anthropic OAuth (Claude subscription)"
    echo "[opencode] uses its own auth — run: opencode providers login"
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
alias use-azure=use-foundry

llm-mode() {
    if [ "${CLAUDE_CODE_USE_FOUNDRY:-0}" = "1" ]; then
        echo "Azure AI Foundry  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE:-<unset>})"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ] || grep -q '"ANTHROPIC_API_KEY"' "$_CLAUDE_SETTINGS" 2>/dev/null; then
        echo "Anthropic API key  (base: ${ANTHROPIC_BASE_URL:-https://api.anthropic.com})"
    else
        echo "Anthropic OAuth (Claude subscription)"
    fi
}
