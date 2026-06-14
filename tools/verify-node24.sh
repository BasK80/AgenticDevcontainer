#!/usr/bin/env bash
# verify-node24.sh — automated regression test for Step 6.1 (Node 24 LTS bump).
#
# Run this INSIDE the development container AFTER rebuilding the image on
# node:24-bookworm. It proves the bump is safe by checking, with no manual
# steps where avoidable:
#
#   1. Runtime is Node >= 24.
#   2. Every bundled tool (node, npm, claude, opencode, copilot) reports a
#      version (i.e. its install survived the base-image bump).
#   3. Firewall egress still works through the Squid proxy: an allowlisted
#      host is reachable and a non-allowlisted host is blocked (403). This is
#      done with curl, which honours http(s)_proxy. NOTE: since the prior
#      proxy fix removed the global-agent NODE_OPTIONS shim, Node's *native*
#      fetch no longer routes through the proxy on its own — the tools use
#      proxy-aware HTTP libraries, so we test egress at the proxy layer, not
#      via a raw `node -e fetch`.
#   4. The firewall block feed (firewall:8099) is reachable.
#   5. (Best effort, auth-dependent) opencode and claude complete a real
#      model round-trip through the firewall. These need provider creds; if
#      absent they are SKIPPED, not failed.
#
# Exit codes: 0 = all runnable checks passed · 1 = a hard check failed ·
#             2 = passed, but one or more checks were skipped (manual creds).
set -uo pipefail

ALLOW_HOST="${VERIFY_ALLOW_URL:-https://registry.npmjs.org/}"   # on the allowlist
DENY_HOST="${VERIFY_DENY_URL:-https://example.com/}"            # not on the allowlist
FIREWALL_FEED="${VERIFY_FEED_URL:-http://firewall:8099}"
MIN_NODE_MAJOR=24
OPENCODE_TEST="/workspace/tools/test-opencode-providers.sh"

# ── pretty output ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_INFO=""; C_WARN=""; C_OFF=""; fi
ok()   { printf '%s✓ %s%s\n' "$C_OK"   "$*" "$C_OFF"; }
err()  { printf '%s✗ %s%s\n' "$C_ERR"  "$*" "$C_OFF"; }
info() { printf '%s• %s%s\n' "$C_INFO" "$*" "$C_OFF"; }
skip() { printf '%s~ %s%s\n' "$C_WARN" "$*" "$C_OFF"; }
hr()   { printf '────────────────────────────────────────────────────────────\n'; }

FAILED=0; SKIPPED=0

# ── check 1: Node >= 24 ─────────────────────────────────────────────────────
check_node_version() {
    hr; printf 'CHECK 1 — Node runtime is >= %s\n' "$MIN_NODE_MAJOR"; hr
    local v major
    v="$(node --version 2>/dev/null)" || { err "node --version failed"; FAILED=1; return; }
    major="${v#v}"; major="${major%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_NODE_MAJOR )); then
        ok "node ${v} (>= ${MIN_NODE_MAJOR})"
    else
        err "node ${v} is below ${MIN_NODE_MAJOR} — image not rebuilt on node:24-bookworm?"
        FAILED=1
    fi
}

# ── check 2: every tool reports a version ───────────────────────────────────
check_tool_versions() {
    hr; printf 'CHECK 2 — bundled tools survived the bump\n'; hr
    local tool
    for tool in node npm claude opencode copilot; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            err "${tool}: not on PATH"; FAILED=1; continue
        fi
        local out
        if out="$("$tool" --version 2>&1 | head -1)"; then
            ok "${tool}: ${out}"
        else
            err "${tool}: --version exited non-zero"; FAILED=1
        fi
    done
}

# ── check 3: proxy egress allow + deny ──────────────────────────────────────
check_proxy_egress() {
    hr; printf 'CHECK 3 — firewall egress (allow + deny) via Squid proxy\n'; hr
    [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]] \
        && info "proxy: ${https_proxy:-$HTTPS_PROXY}" \
        || { err "no https_proxy in env — compose proxy block missing?"; FAILED=1; }

    local code
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "$ALLOW_HOST" 2>/dev/null)" || code="000"
    if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
        ok "allowlisted ${ALLOW_HOST} reachable (HTTP ${code})"
    else
        err "allowlisted ${ALLOW_HOST} NOT reachable (HTTP ${code}) — egress broken"
        FAILED=1
    fi

    # A denied host should fail the CONNECT tunnel with 403 (curl exit 56).
    local out rc
    out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$DENY_HOST" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] && grep -q '403' <<<"$out"; then
        ok "non-allowlisted ${DENY_HOST} blocked by firewall (403 CONNECT tunnel failed)"
    elif [[ $rc -ne 0 ]]; then
        ok "non-allowlisted ${DENY_HOST} blocked (curl exit ${rc})"
    else
        err "non-allowlisted ${DENY_HOST} was REACHABLE — firewall not enforcing default-deny"
        FAILED=1
    fi
}

# ── check 4: block feed reachable ───────────────────────────────────────────
check_block_feed() {
    hr; printf 'CHECK 4 — firewall block feed reachable\n'; hr
    # firewall is in NO_PROXY, so this is a direct in-network call.
    if curl -sS --max-time 10 "$FIREWALL_FEED" >/tmp/verify-feed.txt 2>/dev/null; then
        ok "block feed ${FIREWALL_FEED} reachable ($(wc -l </tmp/verify-feed.txt) lines)"
        info "most recent denials:"
        grep -E 'DENIED|/403' /tmp/verify-feed.txt 2>/dev/null | tail -3 | sed 's/^/    │ /' \
            || info "    │ (none recorded yet)"
    else
        err "block feed ${FIREWALL_FEED} unreachable"
        FAILED=1
    fi
}

# ── check 5: tool round-trips (auth-dependent, best effort) ─────────────────
check_roundtrips() {
    hr; printf 'CHECK 5 — tool round-trips through the firewall (best effort)\n'; hr

    # opencode — delegate to the dedicated provider test (api-key phase is
    # fully automatic). Only run it when a credential is actually available,
    # otherwise the absence is a SKIP, not a failure.
    local oc_key=""
    [[ -f "$HOME/.config/opencode/opencode.json" ]] && \
        oc_key="$(jq -r '.provider.anthropic.options.apiKey // ""' \
            "$HOME/.config/opencode/opencode.json" 2>/dev/null)"
    if [[ ! -x "$OPENCODE_TEST" ]]; then
        skip "opencode: ${OPENCODE_TEST} not executable — SKIPPED"; SKIPPED=1
    elif [[ -z "${ANTHROPIC_API_KEY:-}" && -z "$oc_key" ]]; then
        skip "opencode: no API key (env or opencode.json) — SKIPPED"; SKIPPED=1
    else
        info "opencode: running ${OPENCODE_TEST##*/} apikey"
        if "$OPENCODE_TEST" apikey; then ok "opencode: round-trip PASS"
        else err "opencode: round-trip FAILED"; FAILED=1; fi
    fi

    # claude — non-interactive one-shot if a credential is present.
    if [[ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
        || [[ -f "$HOME/.claude/.credentials.json" ]]; then
        local sentinel="CLAUDE_RT_OK" out
        info "claude: one-shot completion via 'claude -p'"
        out="$(timeout 120 claude -p "Reply with exactly this token and nothing else: ${sentinel}" 2>&1)"
        if grep -q "$sentinel" <<<"$out"; then
            ok "claude: round-trip PASS"
        else
            err "claude: no valid completion"
            printf '%s\n' "$out" | tail -8 | sed 's/^/    │ /'
            FAILED=1
        fi
    else
        skip "claude: no ANTHROPIC_API_KEY / OAuth token / credentials — SKIPPED"; SKIPPED=1
    fi

    # copilot — device/browser login can't be scripted; flag for manual check.
    skip "copilot: interactive login not scriptable — verify manually with 'copilot' once"
    SKIPPED=1
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    printf '%sStep 6.1 — Node 24 LTS regression verification%s\n' "$C_INFO" "$C_OFF"
    check_node_version
    check_tool_versions
    check_proxy_egress
    check_block_feed
    check_roundtrips

    hr; printf 'SUMMARY\n'; hr
    if [[ $FAILED -ne 0 ]]; then
        err "one or more hard checks FAILED — do NOT ship the Node 24 image yet"
        exit 1
    fi
    if [[ $SKIPPED -ne 0 ]]; then
        ok "all runnable checks passed"
        skip "some auth-dependent checks were skipped — run them once creds are present"
        exit 2
    fi
    ok "all checks passed — Node 24 image verified"
    exit 0
}

main "$@"
