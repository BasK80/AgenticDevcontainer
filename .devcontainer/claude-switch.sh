# claude-switch.sh — switch Claude Code between Azure AI Foundry and the
# direct Anthropic API (Claude subscription / OAuth token).
#
# Sourced from ~/.zshrc by post-create.sh. Defines three commands:
#   use-foundry     route Claude through Azure AI Foundry
#   use-anthropic   route Claude through the direct Anthropic API
#   claude-mode     show the currently active provider
#
# Both `use-*` commands rewrite ~/.claude/settings.json AND export/unset
# the relevant environment variables in the current shell so the next
# `claude` invocation picks them up.

# Defaults — override by exporting these before sourcing this file.
: "${ANTHROPIC_FOUNDRY_RESOURCE:=mowiwo-workshop-agentic-resource}"
: "${ANTHROPIC_DEFAULT_SONNET_MODEL:=claude-sonnet-4-6}"
: "${ANTHROPIC_DEFAULT_OPUS_MODEL:=claude-opus-4-6}"
: "${ANTHROPIC_DEFAULT_HAIKU_MODEL:=claude-haiku-4-5}"

_CLAUDE_SETTINGS="$HOME/.claude/settings.json"

_claude_write_settings() {
    # $1 = "foundry" | "anthropic"
    mkdir -p "$(dirname "$_CLAUDE_SETTINGS")"
    if [ "$1" = "foundry" ]; then
        cat > "$_CLAUDE_SETTINGS" <<EOF
{
  "env": {
    "CLAUDE_CODE_USE_FOUNDRY": "1",
    "ANTHROPIC_FOUNDRY_RESOURCE": "${ANTHROPIC_FOUNDRY_RESOURCE}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${ANTHROPIC_DEFAULT_SONNET_MODEL}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${ANTHROPIC_DEFAULT_OPUS_MODEL}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${ANTHROPIC_DEFAULT_HAIKU_MODEL}"
  }
}
EOF
    else
        cat > "$_CLAUDE_SETTINGS" <<'EOF'
{
  "env": {}
}
EOF
    fi
}

use-foundry() {
    export CLAUDE_CODE_USE_FOUNDRY=1
    export ANTHROPIC_FOUNDRY_RESOURCE
    export ANTHROPIC_DEFAULT_SONNET_MODEL
    export ANTHROPIC_DEFAULT_OPUS_MODEL
    export ANTHROPIC_DEFAULT_HAIKU_MODEL
    _claude_write_settings foundry
    echo "[claude] provider: Azure AI Foundry  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE})"
    if ! az account show >/dev/null 2>&1; then
        echo "[claude] not logged in to Azure — run: az login"
    fi
}

use-anthropic() {
    unset CLAUDE_CODE_USE_FOUNDRY
    unset ANTHROPIC_FOUNDRY_RESOURCE
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    _claude_write_settings anthropic
    echo "[claude] provider: Anthropic direct API (Claude subscription)"
    echo "[claude] launching: claude login"
    claude login
}

# Convenience aliases.
alias use-claude=use-anthropic
alias use-azure=use-foundry

claude-mode() {
    if [ "${CLAUDE_CODE_USE_FOUNDRY:-0}" = "1" ]; then
        echo "Azure AI Foundry  (resource: ${ANTHROPIC_FOUNDRY_RESOURCE:-<unset>})"
    else
        echo "Anthropic direct API"
    fi
}
