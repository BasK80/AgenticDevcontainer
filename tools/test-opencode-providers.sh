#!/usr/bin/env bash
# test-opencode-providers.sh — verify `opencode` actually completes a model
# round-trip under both Anthropic auth modes that llm-switch.sh configures:
#
#   1. Anthropic API key  (use-anthropic-key → opencode.json
#                          provider.anthropic.options.apiKey [+ baseURL])
#   2. Anthropic OAuth     (use-anthropic + a one-time `opencode auth login`)
#
# The API-key phase is fully automatic. The OAuth phase needs a one-time
# interactive browser/device login that cannot be scripted, so the script
# detects whether that login exists and, if not, prints the exact manual
# steps and stops.
#
# Usage:
#   tools/test-opencode-providers.sh                # both phases (guided)
#   tools/test-opencode-providers.sh apikey         # API-key phase only
#   tools/test-opencode-providers.sh oauth          # OAuth phase only
#
# Environment overrides:
#   OPENCODE_TEST_MODEL    model id to round-trip      (default: claude-haiku-4-5)
#   OPENCODE_TEST_TIMEOUT  per-call timeout in seconds (default: 120)
#
# Exit codes: 0 = all requested phases passed · 1 = a phase failed ·
#             2 = manual action required (OAuth not logged in yet)
set -uo pipefail

MODEL="${OPENCODE_TEST_MODEL:-claude-haiku-4-5}"
TIMEOUT="${OPENCODE_TEST_TIMEOUT:-120}"
SENTINEL="OPENCODE_RT_OK"
PROMPT="Reply with exactly this token and nothing else: ${SENTINEL}"
SWITCH_SRC="/workspace/.devcontainer/development/llm-switch.sh"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"

# ── pretty output ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_INFO=""; C_OFF=""; fi
ok()   { printf '%s✓ %s%s\n' "$C_OK"  "$*" "$C_OFF"; }
err()  { printf '%s✗ %s%s\n' "$C_ERR" "$*" "$C_OFF"; }
info() { printf '%s• %s%s\n' "$C_INFO" "$*" "$C_OFF"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# ── shared helpers ──────────────────────────────────────────────────────────
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# Run one non-interactive opencode round-trip. Returns 0 only if the model
# echoes the sentinel; on failure dumps the (cleaned) output for diagnosis.
roundtrip() {
    local label="$1" out clean
    info "round-trip ($label): opencode run -m anthropic/${MODEL}"
    out="$(timeout "$TIMEOUT" opencode run -m "anthropic/${MODEL}" "$PROMPT" 2>&1)"
    clean="$(printf '%s' "$out" | strip_ansi)"
    if grep -q "$SENTINEL" <<<"$clean"; then
        ok "$label: opencode returned a valid completion"
        return 0
    fi
    err "$label: no valid completion (sentinel '$SENTINEL' not found)"
    printf '%s\n' "$clean" | sed 's/^/    │ /' | tail -15
    return 1
}

preflight() {
    local missing=0
    command -v opencode >/dev/null || { err "opencode not on PATH"; missing=1; }
    command -v jq       >/dev/null || { err "jq not on PATH"; missing=1; }
    [[ -f "$SWITCH_SRC" ]] || { err "llm-switch.sh not found at $SWITCH_SRC"; missing=1; }
    [[ $missing -eq 0 ]] || exit 1
    # Pull in use-anthropic-key / use-anthropic without re-applying the
    # persisted choice (that only fires in interactive shells).
    # shellcheck disable=SC1090
    source "$SWITCH_SRC"
    ok "preflight: opencode $(opencode --version 2>/dev/null | head -1), jq, llm-switch.sh present"
}

# ── phase 1: Anthropic API key ──────────────────────────────────────────────
test_apikey() {
    hr; printf 'PHASE 1 — Anthropic API key\n'; hr
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        info "applying use-anthropic-key (ANTHROPIC_API_KEY present in env)"
        use-anthropic-key >/dev/null
    else
        info "ANTHROPIC_API_KEY not in env — relying on existing opencode.json"
    fi
    local key
    key="$(jq -r '.provider.anthropic.options.apiKey // ""' "$OPENCODE_CONFIG" 2>/dev/null)"
    if [[ -z "$key" ]]; then
        err "no apiKey in $OPENCODE_CONFIG — export ANTHROPIC_API_KEY and re-run, or run use-anthropic-key"
        return 1
    fi
    ok "opencode.json has provider.anthropic.options.apiKey (${key:0:6}…)"
    info "baseURL: $(jq -r '.provider.anthropic.options.baseURL // "https://api.anthropic.com (default)"' "$OPENCODE_CONFIG")"
    roundtrip "api-key"
}

# ── phase 2: Anthropic OAuth ────────────────────────────────────────────────
# opencode resolves Anthropic credentials from opencode.json's
# provider.anthropic.options.apiKey BEFORE the OAuth credential in auth.json.
# So to genuinely exercise the OAuth path we temporarily move the pinned key
# out of the config, then restore it on exit.
RESTORE_CONFIG=""
restore_config() {
    if [[ -n "$RESTORE_CONFIG" && -f "$RESTORE_CONFIG" ]]; then
        mv -f "$RESTORE_CONFIG" "$OPENCODE_CONFIG"
        info "restored original opencode.json"
    fi
}

test_oauth() {
    hr; printf 'PHASE 2 — Anthropic OAuth (Claude subscription)\n'; hr
    info "applying use-anthropic (Claude Code → OAuth; opencode uses its own auth)"
    # _LLM_NO_LOGIN keeps this from launching Claude Code's interactive login.
    _LLM_NO_LOGIN=1 use-anthropic >/dev/null 2>&1 || true

    # Is opencode logged in to Anthropic via OAuth?
    local has_oauth="no"
    if [[ -f "$OPENCODE_AUTH" ]] && jq -e '.anthropic.type=="oauth"' "$OPENCODE_AUTH" >/dev/null 2>&1; then
        has_oauth="yes"
    fi
    if [[ "$has_oauth" != "yes" ]]; then
        err "opencode is not logged in to Anthropic via OAuth"
        cat <<EOF

  ┌─ MANUAL STEP REQUIRED ─────────────────────────────────────────────┐
  │ Run the interactive login once, then re-run this phase:            │
  │                                                                    │
  │     opencode auth login                                            │
  │       → choose 'Anthropic'                                         │
  │       → choose 'Claude Pro/Max' (the OAuth option, not API key)    │
  │       → complete the browser / device-code flow                    │
  │                                                                    │
  │     tools/test-opencode-providers.sh oauth                         │
  │                                                                    │
  │ Note: api.anthropic.com and claude.ai must be on the firewall      │
  │ allowlist for the login + round-trip to succeed.                   │
  └────────────────────────────────────────────────────────────────────┘
EOF
        return 2
    fi
    ok "opencode has an Anthropic OAuth credential in auth.json"

    # Temporarily strip a pinned apiKey so OAuth is actually used.
    local pinned
    pinned="$(jq -r '.provider.anthropic.options.apiKey // ""' "$OPENCODE_CONFIG" 2>/dev/null)"
    if [[ -n "$pinned" ]]; then
        RESTORE_CONFIG="${OPENCODE_CONFIG}.testbak"
        trap restore_config EXIT
        cp -f "$OPENCODE_CONFIG" "$RESTORE_CONFIG"
        jq 'del(.provider.anthropic.options.apiKey, .provider.anthropic.options.baseURL)' \
            "$RESTORE_CONFIG" > "$OPENCODE_CONFIG"
        info "temporarily removed pinned apiKey/baseURL from opencode.json (restored on exit)"
    fi

    roundtrip "oauth"
    local rc=$?
    restore_config; trap - EXIT; RESTORE_CONFIG=""
    return $rc
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    local phase="${1:-both}"
    preflight
    local rc_key=0 rc_oauth=0
    case "$phase" in
    apikey) test_apikey; rc_key=$? ;;
    oauth)  test_oauth;  rc_oauth=$? ;;
    both)   test_apikey; rc_key=$?
            test_oauth;  rc_oauth=$? ;;
    *) err "unknown phase '$phase' (use: apikey | oauth | both)"; exit 1 ;;
    esac

    hr; printf 'SUMMARY\n'; hr
    [[ "$phase" == "oauth"  ]] || { [[ $rc_key   -eq 0 ]] && ok "API key: PASS" || err "API key: FAIL"; }
    if [[ "$phase" != "apikey" ]]; then
        case $rc_oauth in
        0) ok  "OAuth:   PASS" ;;
        2) info "OAuth:   SKIPPED (manual login required — see above)" ;;
        *) err "OAuth:   FAIL" ;;
        esac
    fi
    # Manual-required (2) is not a hard failure; real failures (1) are.
    [[ $rc_key -eq 1 || $rc_oauth -eq 1 ]] && exit 1
    [[ $rc_oauth -eq 2 ]] && exit 2
    exit 0
}

main "$@"
