# Claude Code Dev Container

A generic hardened Dev Container for running Claude Code (and other AI coding agents) safely. Provides default-deny network isolation, project-scoped state, and non-root execution out of the box. Azure AI Foundry support is included as an opt-in overlay.

## Goal

1. **Blast-radius containment.** Limits what a running agent can touch to the project workspace and an explicit allowlist of network destinations — no host home directory, no cloud credentials, no SSH keys.

2. **Project isolation.** Each project gets its own container, caches, and Claude session state. No cross-project bleed.

## Security measures

**Default-DENY outbound network.** All outbound traffic is dropped unless it matches an allowlist in `init-firewall.sh`. Allowed destinations cover Anthropic APIs, GitHub, common package registries, and Azure endpoints required for Foundry auth/API access.

**Azure browser callback ingress (localhost-only).** To support `az login` browser flow in-container, localhost ports `8400-8999` are published from host to container and explicitly allowed through the container firewall. This is limited to `127.0.0.1` on the host.

**Non-root user.** Container runs as `devuser` (UID 1000). The only sudo privilege granted is running `init-firewall.sh` — nothing else.

**Resource limits.** CPU (4 cores), memory (8 GB), PID (512) caps prevent a runaway agent from affecting the host.

**Read-only git identity.** `~/.gitconfig` is bind-mounted read-only — the agent cannot rewrite git hooks or other config.

**SSH key isolation (optional).** SSH agent forwarding is supported but disabled by default. When enabled, keys stay on the host and the container can only sign operations, never read key material. See the Caveats section for platform-specific setup.

**No Docker socket.** `/var/run/docker.sock` is not mounted. Mounting it is a one-line host root escalation.

**Project-scoped volumes.** All persistent state (Claude config, caches, history) lives in named Docker volumes prefixed with the project directory name. Separate projects = separate volumes.

## File guide

### `devcontainer.json`
Orchestration config: mounts, env vars, resource limits, startup hooks. In this repo it also enables Foundry env vars and publishes localhost callback ports (`127.0.0.1:8400-8999:8400-8999`) for `az login` browser auth.

### `Dockerfile`
Image recipe. Installs dev tools, the non-root user, the restricted sudoers entry, and Claude Code. Also installs Azure CLI and GitHub CLI (comment out either if unused).

### `init-firewall.sh`
Runs at every container start. Flushes iptables, sets default-DROP, resolves allowlisted FQDNs to IPs, and opens only ports 80/443 to those IPs. It also allows inbound TCP `8400-8999` for Azure CLI localhost callback handling.

### `post-create.sh`
Runs once after first container creation. Generic hook for project setup (dependency install, first-run config). In this repo it writes `~/.claude/settings.json` for Foundry routing and enables Azure CLI browser login mode when Foundry is enabled.

## How to use

1. Drop `.devcontainer/` into your project root.
2. "Reopen in Container" from VS Code or Cursor, or run `devcontainer up --workspace-folder .`
3. First build: a few minutes. Subsequent starts: seconds.
4. Open a terminal and run `claude`.

## Azure AI Foundry overlay

This repo is currently configured to route Claude Code through Azure AI Foundry by default. Update the resource values below to match your environment.

### 1. Firewall - verify your resource endpoints

In `init-firewall.sh`, verify the Azure section includes your endpoints:

```bash
# Microsoft Entra ID
"login.microsoftonline.com"
"login.microsoft.com"
"login.live.com"
"graph.microsoft.com"

# Azure Resource Manager
"management.azure.com"
"management.core.windows.net"

# Azure AI Foundry portal
"ai.azure.com"

# Your specific resource endpoint — find it in the Azure portal under
# your resource → Keys and Endpoint, or:
# az cognitiveservices account show --name <name> --resource-group <rg> \
#   --query "properties.endpoints" -o json
"YOUR-RESOURCE.services.ai.azure.com"
```

> **Important:** apex domains like `services.ai.azure.com` have no A records and will never resolve. Only add the full per-resource subdomain.

### 2. devcontainer.json - verify Foundry env vars

```jsonc
"CLAUDE_CODE_USE_FOUNDRY": "1",
"ANTHROPIC_FOUNDRY_RESOURCE": "YOUR-RESOURCE-NAME",
"ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
"ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6",
"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5"
```

### 3. post-create.sh - verify settings writer and az login mode

The script writes `~/.claude/settings.json` with Foundry env settings on first create and sets Azure CLI to browser login mode (`core.login_experience_v2=on`) when Foundry is enabled.

Additionally, `postStartCommand` in `devcontainer.json` reapplies the same Azure CLI setting on each container start as a self-heal for existing containers.

### 4. Request access and authenticate

- Request access to your Foundry resource via your organisation's access package (if applicable).
- Inside the container, run `az login` and select the correct subscription.
- Complete sign-in in the host browser when prompted; the localhost callback is forwarded to the container automatically.
- Launch Claude from the same terminal session: `claude`.

Azure tokens expire after roughly 1 hour of inactivity. Re-run `az login` if Claude starts returning auth errors.

### Quick verify (Option B)

Run these checks after a container restart to confirm browser-callback login is wired correctly.

Inside the container:

```bash
# 1) Foundry mode is enabled
echo "CLAUDE_CODE_USE_FOUNDRY=${CLAUDE_CODE_USE_FOUNDRY:-unset}"

# 2) Azure CLI is set to browser login mode
az config get core.login_experience_v2 --query "value" -o tsv

# 3) Firewall allows callback ingress range
sudo iptables -S INPUT | grep -- '--dport 8400:8999'
```

On the host (PowerShell):

```powershell
# Replace YOURPROJECT with your actual folder basename.
docker ps --filter "name=claude-YOURPROJECT" --format "{{.Names}}\t{{.Ports}}"
```

Expected output should include a localhost mapping for `8400-8999`, similar to:
`127.0.0.1:8400-8999->8400-8999/tcp`

Login smoke test (inside container):

```bash
az login
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
```

If `az login` still hangs after browser sign-in, rerun once with debug and inspect the localhost callback line:

```bash
az login --debug 2>&1 | tee /tmp/az-login-debug.log
grep -Ei 'localhost|127\.0\.0\.1|redirect' /tmp/az-login-debug.log | tail -30
```

### Switching back to direct Anthropic API

Set `CLAUDE_CODE_USE_FOUNDRY` to `"0"` in `devcontainer.json`, remove or adjust Foundry keys in `~/.claude/settings.json`, and restart Claude.

## Multi-agent inside this container

No separate containers needed. Use git worktrees:

```bash
mkdir -p ~/trees
git -C /workspace worktree add ~/trees/feature-a -b feature/a
git -C /workspace worktree add ~/trees/feature-b -b feature/b

tmux new-session -d -s agents
tmux send-keys -t agents "cd ~/trees/feature-a && claude" Enter
tmux split-window -t agents
tmux send-keys -t agents "cd ~/trees/feature-b && claude" Enter
tmux attach -t agents
```

## Caveats

**IP filtering is snapshot-based.** The firewall resolves FQDNs once at startup. If Azure or a CDN rotates IPs, calls may start failing. Re-run `sudo /usr/local/bin/init-firewall.sh` to refresh. For tighter enforcement, use an SNI-filtering HTTPS proxy.

**Azure parent domains have no A records.** Only per-resource subdomains resolve. Never add apex domains like `services.ai.azure.com` to the firewall — they will always warn and provide no protection.

**SSH agent forwarding on Windows** requires `npiperelay` + the Windows OpenSSH Authentication Agent service. Until configured, use HTTPS + PAT or `gh auth login`.

**macOS bind mount performance.** `node_modules`, `.venv`, and similar high-IOPS paths are on named volumes in this config. If you add new high-write paths, follow the same pattern.

**Firewall rules reset on container restart.** `postStartCommand` re-applies them automatically.

## Debugging blocked traffic

```bash
sudo dmesg | grep fw-drop-out | tail -30
dig -x <blocked-ip>   # find out which hostname the IP belongs to
# Add the hostname to ALLOWED_DOMAINS and re-run:
sudo /usr/local/bin/init-firewall.sh
```

## Cleanup

```bash
docker rm -f $(docker ps -aq --filter "name=claude-YOURPROJECT")
docker volume ls --format '{{.Name}}' | grep '^YOURPROJECT-' | xargs docker volume rm
```
