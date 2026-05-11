#!/usr/bin/env bash
# init-firewall.sh — default-deny outbound + domain allowlist.
# Runs at every container start via postStartCommand. Requires NET_ADMIN.
set -euo pipefail

echo "[firewall] flushing existing rules..."
iptables -F && iptables -X
iptables -t nat -F && iptables -t nat -X
iptables -t mangle -F && iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

ipset create allowed-domains hash:net family inet hashsize 4096 maxelem 65536

# ── Default policies ──────────────────────────────────────────────────────
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# ── Loopback + established connections ────────────────────────────────────
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Azure CLI browser login callback (localhost on host -> container published ports).
iptables -A INPUT -p tcp --dport 8400:8999 -j ACCEPT

# ── DNS ───────────────────────────────────────────────────────────────────
RESOLVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | sort -u)
for ns in $RESOLVERS 1.1.1.1 8.8.8.8; do
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

# ── Allowlist ─────────────────────────────────────────────────────────────
# Add or remove entries to match what your project actually needs.
# NOTE: only add hostnames that have A records (i.e. real endpoints).
# Parent/namespace domains like "services.ai.azure.com" have no A records
# and will always fail to resolve — add the full per-resource subdomain instead.
ALLOWED_DOMAINS=(
    # Anthropic / Claude Code
    "api.anthropic.com"
    "console.anthropic.com"
    "claude.ai"

    # npm / Node
    "registry.npmjs.org"
    "registry.yarnpkg.com"

    # Python (comment out if not using Python)
    "pypi.org"
    "files.pythonhosted.org"

    # Javascript packages
    "cdn.jsdelivr.net"

    # GitHub
    "github.com"
    "api.github.com"
    "codeload.github.com"
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"
    "ghcr.io"

    # Debian package repos
    "deb.debian.org"
    "security.debian.org"
    "packages.microsoft.com"

    # ── Azure AI Foundry overlay ──────────────────────────────────────────
    # Uncomment the blocks below when using Azure. Add your specific resource
    # endpoint — find it in the Azure portal under your resource → Endpoints,
    # or: az cognitiveservices account show \
    #       --name <name> --resource-group <rg> \
    #       --query "properties.endpoints" -o json
    #
    # Microsoft Entra ID (required for az login)
    "login.microsoftonline.com"
    "login.microsoft.com"
    "login.live.com"
    "graph.microsoft.com"
    #
    # Azure Resource Manager
    "management.azure.com"
    "management.core.windows.net"
    #
    # Azure AI Foundry portal
    "ai.azure.com"
    #
    # Your per-resource endpoints (one line each — replace placeholders):
    # "YOUR-RESOURCE.services.ai.azure.com"
    # "YOUR-RESOURCE.openai.azure.com"
    # "YOUR-RESOURCE.cognitiveservices.azure.com"
    # "YOUR-STORAGE.blob.core.windows.net"
    # ─────────────────────────────────────────────────────────────────────
)

resolve_and_add() {
    local d="$1"
    local ips
    ips=$(dig +short +time=2 +tries=2 A "$d" 2>/dev/null \
          | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [[ -z "$ips" ]]; then
        echo "[firewall] WARN: could not resolve $d"
        return
    fi
    while IFS= read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
    echo "[firewall] $d -> $(echo "$ips" | tr '\n' ' ')"
}

for d in "${ALLOWED_DOMAINS[@]}"; do resolve_and_add "$d"; done

# ── Allow HTTPS/HTTP to allowlisted IPs ───────────────────────────────────
iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst --dport 80  -j ACCEPT

# ── Log drops (debug aid — comment out once stable) ───────────────────────
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "[fw-drop-out] " --log-level 4

echo "[firewall] done. $(ipset list allowed-domains | grep -c '^[0-9]') IPs allowlisted."
