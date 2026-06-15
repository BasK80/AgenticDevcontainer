#!/usr/bin/env bash
# Welcome banner shown in the terminal that auto-opens on attach (Step 4.1).
# Printed by the "Open terminal on attach" task in .vscode/tasks.json just
# before it `exec`s the login shell, so it greets the user every time the
# container is (re)attached — unlike post-create.sh, which runs once and logs
# to the creation output rather than the interactive terminal.

_provider_label() {
    local mode
    mode="$(cat "$HOME/.llm-provider" 2>/dev/null)"
    case "$mode" in
        foundry)       echo "Azure AI Foundry (az login)" ;;
        anthropic-key) echo "Anthropic API key" ;;
        anthropic)     echo "Claude subscription (OAuth)" ;;
        *)             echo "Claude subscription (OAuth)" ;;
    esac
}

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  AI tools:  claude (Claude Code)  ·  opencode  ·  copilot    │"
echo "│                                                              │"
printf "│  Active LLM provider: %-39s│\n" "$(_provider_label)"
echo "│                                                              │"
echo "│  Switch LLM provider at any time:                            │"
echo "│    use-anthropic     → Claude subscription (OAuth) (default) │"
echo "│    use-foundry       → Azure AI Foundry (run az login)       │"
echo "│    use-anthropic-key → Anthropic API key (static fallback)   │"
echo "│    llm-mode          → show active provider                  │"
echo "│                                                              │"
echo "│  Open http://127.0.0.1:8088 on the host PC to access the     │"
echo "│  firewall management tooling.                                │"
echo "└──────────────────────────────────────────────────────────────┘"
