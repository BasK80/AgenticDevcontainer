#!/usr/bin/env bash
# Welcome banner shown in the terminal that auto-opens on attach (Step 4.1).
# Printed by the "Open terminal on attach" task in .vscode/tasks.json just
# before it `exec`s the login shell, so it greets the user every time the
# container is (re)attached — unlike post-create.sh, which runs once and logs
# to the creation output rather than the interactive terminal.
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  AI tools:  claude (Claude Code)  ·  opencode  ·  copilot    │"
echo "│                                                              │"
echo "│  Switch LLM provider at any time:                          │"
echo "│    use-anthropic     → Claude subscription (OAuth) (default)  │"
echo "│    use-foundry       → Azure AI Foundry (run az login)        │"
echo "│    use-anthropic-key → Anthropic API key (static fallback)    │"
echo "│    llm-mode          → show active provider                   │"
echo "└──────────────────────────────────────────────────────────────┘"
