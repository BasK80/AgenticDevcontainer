# Claude Code Dev Container

A generic hardened Dev Container for running Claude Code (and other AI coding agents) safely. Provides default-deny network isolation, project-scoped state, and non-root execution out of the box. Azure AI Foundry support is included as an opt-in overlay.

## Goal

1. **Blast-radius containment.** Limits what a running agent can touch to the project workspace and an explicit allowlist of network destinations — no host home directory, no cloud credentials, no SSH keys.

2. **Project isolation.** Each project gets its own container, caches, and Claude session state. No cross-project bleed.

## Security measures

**Default-DENY outbound network via a separate firewall container.** The dev container (`development`) is on a Docker `internal: true` network with **no route to the internet**. The only egress path is a Squid proxy running in a sibling `firewall` container that enforces a domain allowlist (see [.devcontainer/firewall/allowlist.default](.devcontainer/firewall/allowlist.default)). Denied requests return a readable `403`. Tools that ignore `HTTP(S)_PROXY` fail closed (no route out), they don't bypass the firewall.

**Out-of-band management plane (QoL).** A third `control` container hosts the `allow`/`deny` commands, the policy volume, and the web dashboard. It sits on a separate network (`egress` only, never `internal`) and is therefore unreachable from `development`. The hard isolation is the network topology — `development` has no route to `control` regardless of what `control` runs. `control` is a convenience layer: the security would hold even if it were removed and the policy volume were edited directly. An agent inside `development` cannot modify its own allowlist.

**Domain-based filtering.** The allowlist is hostnames, not snapshotted IPs — resilient to CDN/Azure IP rotation. No periodic re-resolution needed.

**Azure browser callback ingress (localhost-only).** To support `az login` browser flow in-container, localhost ports `8400-8999` are published from host to `development`. The firewall only filters egress, so inbound publishes don't bypass it. Limited to `127.0.0.1` on the host.

**Non-root user, no sudo.** Container runs as `devuser` (UID 1000) with no sudo privileges whatsoever.

**Resource limits.** CPU (4 cores), memory (8 GB), PID (512) caps prevent a runaway agent from affecting the host.

**Read-only git identity.** `~/.gitconfig` is bind-mounted read-only — the agent cannot rewrite git hooks or other config.

**SSH key isolation (optional).** SSH agent forwarding is supported but disabled by default. When enabled, keys stay on the host and the container can only sign operations, never read key material. See the Caveats section for platform-specific setup.

**No Docker socket.** `/var/run/docker.sock` is not mounted. Mounting it is a one-line host root escalation.

**Project-scoped volumes.** All persistent state (Claude config, caches, history) lives in named Docker volumes prefixed with the project directory name. Separate projects = separate volumes.

## File guide

### `.devcontainer/devcontainer.json`
VS Code dev-container orchestration. Points at `docker-compose.yml`, selects `development` as the attach target, declares the post-create hook, and runs an `initializeCommand` on the host that writes `.devcontainer/.env` (per-project naming + host env passthrough).

### `.devcontainer/docker-compose.yml`
Defines the three services and two networks:
- `development` — the container VS Code attaches to. Internal-only network. All persistent state on per-project named volumes (`${LOCAL_WORKSPACE_FOLDER_BASENAME}-*`). Publishes `127.0.0.1:8400-8999` for `az login`. CPU/memory/PID limits set here.
- `firewall` — Squid on `internal` + `egress`. The only path to the internet.
- `control` — hosts `allow`/`deny`; on `egress` only, not reachable from `development`.

### `.devcontainer/development/Dockerfile`
Image for the dev container. Installs dev tools, Azure CLI, GitHub CLI, non-root `devuser`, Claude Code, and `global-agent` (so Node's native `fetch`/`https` honour the proxy). Sets `HTTP(S)_PROXY=http://firewall:3128` and `NODE_OPTIONS=-r global-agent/bootstrap` image-wide.

### `.devcontainer/development/post-create.sh`
Runs once after first container creation. Generic hook for project setup (dependency install, first-run config). Wires up `claude-switch.sh` and writes `~/.claude/settings.json` for Foundry routing.

### `.devcontainer/development/claude-switch.sh`
Defines `use-anthropic-key` / `use-foundry` / `use-anthropic` / `claude-mode` shell commands for switching the Claude provider in-place. The API-key mode (`ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL`) is the default.

### `.devcontainer/firewall/`
Squid image: `squid.conf` (ACL), `allowlist.default` (baked-in default domain list), `entrypoint.sh`, `watcher.sh` (hot-reloads policy every 5s), `blockfeed.sh` (read-only HTTP feed of recent blocks on `:8099`), `fw` (management script — see [Manage the allowlist](#manage-the-allowlist-from-the-host)).

### `.devcontainer/control/`
Out-of-band management plane, unreachable from `development`. Holds the policy volume and the management scripts called by the web dashboard (`allow.sh`, `deny.sh`, `list_allows.sh`, `show_blocks.sh`, `tail_firewall.sh`). These scripts write to the same shared `policy` volume as the firewall container's `fw` script, so the dashboard and the CLI are always in sync.

## How to use

1. Drop `.devcontainer/` into your project root.
2. "Reopen in Container" from VS Code or Cursor, or run `devcontainer up --workspace-folder .`
3. First build: a few minutes (three images). Subsequent starts: seconds.
4. Open a terminal in the `development` container and run `claude`.

### Manage the allowlist from the host

```bash
# Set once in your host shell (or add to ~/.bashrc / ~/.zshrc):
FW="claude-$(basename "$PWD")-firewall"

docker exec      "$FW" fw allow pypi.org                   # permanent allow
docker exec      "$FW" fw allow files.pythonhosted.org 60  # temporary allow, 60s TTL
docker exec      "$FW" fw deny  pypi.org                   # remove an allow (re-block); perm + temp
docker exec      "$FW" fw list                             # show the live, compiled allowlist
docker exec      "$FW" fw blocks                           # recent blocked requests
docker exec -it  "$FW" fw log                              # follow the access log
```

Changes take effect within ~5s (the firewall watcher reloads Squid). Run these on the **host**, not inside the dev container — `development` is deliberately unable to reach the management plane.

### Web dashboard (localhost only)

A single-page dashboard is served by the `control` container at **<http://127.0.0.1:8088>**. It is bound to `127.0.0.1` only — the same localhost-only pattern as the Azure login ports — and is not reachable from inside `development`.

| Section | What it shows |
|---|---|
| **Live Traffic** | Real-time stream of every proxied request, colour-coded green (allowed) / red (denied). Collapsible; filter text persists across reloads. |
| **Allowlist** | Permanent and temporary entries. Each row has a **Remove** button. Temporary entries show a live countdown. |
| **Recently Blocked** | Domains with at least one denied request, grouped by host and sorted by recency. One-click **Permanent** / **5m** / **15m** / **1h** and **Custom…** allow buttons per row. |

Every mutation from the dashboard writes to the same shared `policy` volume that the `fw` script modifies directly, so the CLI and the dashboard are always in sync.

### See blocks from inside the dev container
- Each blocked request shows up as a `403` proxy error in your tools.
- Read-only recent-blocks feed: `curl -s http://firewall:8099`

## Anthropic API key (default provider)

When `ANTHROPIC_API_KEY` is exported on the host at the time you open the container, the dev container picks `use-anthropic-key` as the default provider on first create. The key (and an optional `ANTHROPIC_BASE_URL`) is passed in via `initializeCommand` → `.devcontainer/.env` → the `development` service `environment` block in [docker-compose.yml](.devcontainer/docker-compose.yml). `.env` is gitignored, but the key is still readable by anything that can run `docker inspect` on the container — do not use a key you wouldn't put on disk.

The firewall already allows `api.anthropic.com`. If you point `ANTHROPIC_BASE_URL` at a custom host (proxy, gateway), add it to the allowlist: `docker exec "$FW" fw allow your-gateway.example.com`.

### Set the key on the host

Only the shell that launches VS Code / `devcontainer up` needs the variable set; restart VS Code afterwards so it re-runs `initializeCommand`.

**Linux / macOS / WSL** — add to `~/.bashrc`, `~/.zshrc`, or `~/.profile`:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
# Optional — only set if you route through a custom gateway:
# export ANTHROPIC_BASE_URL="https://your-gateway.example.com"
```

Then open a fresh terminal and launch VS Code from it (`code .`) so the variable is inherited.

**Windows (PowerShell)** — persist for the user (no admin needed):

```powershell
[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'sk-ant-...', 'User')
# Optional:
# [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', 'https://your-gateway.example.com', 'User')
```

Then fully quit VS Code (all windows) and relaunch so it picks up the new user environment.

Verify on the host before reopening the container:

```bash
# Linux/macOS/WSL
echo "${ANTHROPIC_API_KEY:0:10}..."
```

```powershell
# PowerShell
"$($env:ANTHROPIC_API_KEY.Substring(0,10))..."
```

Verify inside the container after rebuild:

```bash
claude-mode                                  # should print: Anthropic API key (base: ...)
echo "${ANTHROPIC_API_KEY:0:10}..."          # should print the prefix
grep ANTHROPIC_API_KEY ~/.claude/settings.json
```

If you set the key after the container was already created, run `use-anthropic-key` once in the container shell to rewrite `~/.claude/settings.json`.

### Set the key from inside the container (survives restarts)

You can skip the host setup entirely and configure the key from a shell inside the dev container:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
# Optional — only set if you route through a custom gateway:
# export ANTHROPIC_BASE_URL="https://your-gateway.example.com"
use-anthropic-key
```

`use-anthropic-key` writes the literal value into `~/.claude/settings.json`, which lives on the named Docker volume `${PROJECT}-claude`. Named volumes survive `docker compose down`, container rebuilds, and image rebuilds — only `docker volume rm` (or `docker compose down -v`) removes them. Every new shell will pick up the persisted key on container start.

Notes:
- The host-side passthrough only sets the var when **non-empty** on the host (see [initialize.sh](.devcontainer/initialize.sh)). If the host has no `ANTHROPIC_API_KEY`, the container starts without it set, and the value from `~/.claude/settings.json` is the source of truth.
- The key is stored plaintext in the named volume. Anyone with access to the host Docker daemon can read it (`docker run --rm -v ${PROJECT}-claude:/c alpine cat /c/settings.json`).
- To rotate, just re-run `use-anthropic-key` with a new value exported in the current shell.

## Azure AI Foundry overlay

This repo is currently configured to route Claude Code through Azure AI Foundry by default. Update the resource values below to match your environment.

### 1. Firewall - add your resource endpoints to the allowlist

The default allowlist in [.devcontainer/firewall/allowlist.default](.devcontainer/firewall/allowlist.default) already includes Microsoft Entra ID, Azure Resource Manager, `ai.azure.com`, and the common Azure data-plane wildcards. Add your per-resource endpoints (find them in the Azure portal under your resource → Keys and Endpoint, or `az cognitiveservices account show --name <n> --resource-group <rg> --query "properties.endpoints" -o json`).

Two ways to add:

```bash
# Temporary/iterating — applies within ~5s, no rebuild needed:
docker exec "$FW" fw allow YOUR-RESOURCE.services.ai.azure.com

# Permanent baseline — edit and rebuild the firewall image:
#   1. add the line to .devcontainer/firewall/allowlist.default
#   2. docker compose -f .devcontainer/docker-compose.yml build firewall
#   3. Reopen in Container
```

Note: Squid's `dstdomain` ACL matches by hostname (not IP), so CDN/Azure IP rotation never breaks the allowlist. Wildcard entries (e.g. `.core.windows.net`) match all subdomains.

### 2. claude-switch.sh - verify Foundry defaults

Provider routing now lives in the in-shell switcher [`.devcontainer/development/claude-switch.sh`](.devcontainer/development/claude-switch.sh), not in `devcontainer.json`. Update the defaults near the top:

```bash
: "${ANTHROPIC_FOUNDRY_RESOURCE:=YOUR-RESOURCE-NAME}"
: "${ANTHROPIC_DEFAULT_SONNET_MODEL:=claude-sonnet-4-6}"
: "${ANTHROPIC_DEFAULT_OPUS_MODEL:=claude-opus-4-6}"
: "${ANTHROPIC_DEFAULT_HAIKU_MODEL:=claude-haiku-4-5}"
```

These are written into `~/.claude/settings.json` whenever you run `use-foundry`.

### 3. post-create.sh - verify settings writer and az login mode

[`.devcontainer/development/post-create.sh`](.devcontainer/development/post-create.sh) writes `~/.claude/settings.json` with Foundry env settings on first create and sets Azure CLI to browser login mode (`core.login_experience_v2=on`) when Foundry is enabled.

Additionally, `postStartCommand` in [`devcontainer.json`](.devcontainer/devcontainer.json) reapplies the same Azure CLI setting on each container start as a self-heal for existing containers.

### 4. Request access and authenticate

- Request access to your Foundry resource via your organisation's access package (if applicable).
- Inside the container, run `az login` and select the correct subscription.
- Complete sign-in in the host browser when prompted; the localhost callback is forwarded to the container automatically.
- Launch Claude from the same terminal session: `claude`.

Azure tokens expire after roughly 1 hour of inactivity. Re-run `az login` if Claude starts returning auth errors.

### Quick verify

Run these checks after a container restart to confirm everything is wired correctly.

Inside the container:

```bash
# 1) Foundry mode is enabled
echo "CLAUDE_CODE_USE_FOUNDRY=${CLAUDE_CODE_USE_FOUNDRY:-unset}"

# 2) Azure CLI is set to browser login mode
az config get core.login_experience_v2 --query "value" -o tsv

# 3) Proxy is in effect (no direct egress, only via firewall)
echo "$HTTPS_PROXY"  # http://firewall:3128
curl -sS https://api.github.com/zen   # 200 if allowlisted
curl --noproxy '*' --max-time 5 -sS https://api.github.com/zen; echo "exit=$?"  # nonzero — no direct route
```

On the host:

```bash
# Replace YOURPROJECT with your actual folder basename.
docker ps --filter "name=claude-YOURPROJECT" --format "{{.Names}}\t{{.Ports}}"
```

Expected: three containers (`-development`, `-firewall`, `-control`) and the `development` container should show `127.0.0.1:8400-8999->8400-8999/tcp`.

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

### Switching back to Anthropic

Two options, both clear the Foundry env vars and rewrite `~/.claude/settings.json`:

- `use-anthropic-key` — use a direct Anthropic API key. Requires `ANTHROPIC_API_KEY` (and optionally `ANTHROPIC_BASE_URL`) to be present in the container env — see [Anthropic API key (default provider)](#anthropic-api-key-default-provider) for host-side setup. **Default on first create when the key is set.**
- `use-anthropic` — use the OAuth login flow (Claude subscription). Launches `claude login` on first use.

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

**Domain-based filtering, not IP-based.** Allowlist entries are hostnames. CDN/Azure IP rotation does not break anything. Wildcard entries (e.g. `.core.windows.net`) match all subdomains.

**Node tools need `global-agent`** to honour `HTTPS_PROXY`. The image installs it globally and preloads it via `NODE_OPTIONS=-r global-agent/bootstrap`, which covers `claude`, MCP servers, and the VS Code extension host. A Node script that explicitly clears `NODE_OPTIONS` (rare) will fail closed — that's correct behaviour, not a leak.

**Proxy-unaware tools fail closed.** `development` has no route to the internet outside the proxy. A tool that ignores `HTTP(S)_PROXY` cannot reach anything — there's no fallback path to bypass.

**SSH agent forwarding on Windows** requires `npiperelay` + the Windows OpenSSH Authentication Agent service. Until configured, use HTTPS + PAT or `gh auth login`. The SSH mount line in `docker-compose.yml` is commented out by default.

**macOS bind mount performance.** `node_modules`, `.venv`, and similar high-IOPS paths are on named volumes in this config. If you add new high-write paths, follow the same pattern.

**Allowlist policy persists.** It lives on the `policy` Docker volume and survives container restarts. Edit the baked default in `.devcontainer/firewall/allowlist.default` and rebuild the firewall image to change the seed; use `docker exec "$FW" fw allow|deny` for live edits.

## Debugging blocked traffic

```bash
# From inside the dev container:
curl -s http://firewall:8099 | tail -30

# From the host (FW="claude-$(basename "$PWD")-firewall"):
docker exec      "$FW" fw blocks                           # last 30 access log lines
docker exec -it  "$FW" fw log                              # live tail
docker exec      "$FW" fw list                             # current compiled allowlist
docker exec      "$FW" fw allow <hostname>                 # add the missing destination
docker exec      "$FW" fw allow <hostname> 300             # 5-minute temporary allow while debugging
```

## Cleanup

```bash
# Stop and remove all three containers for this project:
docker compose -f .devcontainer/docker-compose.yml down -v

# Or by name (replace YOURPROJECT with your folder basename):
docker rm -f $(docker ps -aq --filter "name=claude-YOURPROJECT")
docker volume ls --format '{{.Name}}' | grep '^YOURPROJECT-' | xargs -r docker volume rm
```

## Minimal footprint: removing the control container

The `control` container is entirely optional. Security enforcement lives exclusively in the `firewall` container — `control` is a convenience layer (management scripts and the web dashboard) and can be removed without weakening isolation.

### What to change in `docker-compose.yml`

1. **Delete the `control:` service block** (the whole stanza, including `ports`, `volumes`, and `networks`).
2. The `egress` network must **stay** — the `firewall` service needs it to route traffic to the internet.
3. The `policy` and `logs` volumes must **stay** — the `firewall` service mounts them.

Nothing else needs to change. After editing, recreate the stack:

```bash
docker compose -f .devcontainer/docker-compose.yml up -d --remove-orphans
```

> **Note:** If the `policy` volume does not exist yet (first run after removing `control`), create it manually before starting:
> ```bash
> docker volume create claude-YOURPROJECT-policy
> ```
> Replace `YOURPROJECT` with your folder basename.

The web dashboard at `:8088` will no longer be available. The `fw` script inside the firewall container remains fully functional — use it directly:

### Managing the firewall without the control container

```bash
# Set a shell variable for convenience (run on the host):
FW="claude-$(basename "$PWD")-firewall"

docker exec      "$FW" fw allow example.com       # permanent allow
docker exec      "$FW" fw allow example.com 300   # temporary allow, 300s TTL
docker exec      "$FW" fw deny  example.com        # remove an allow (re-block)
docker exec      "$FW" fw list                     # current compiled allowlist
docker exec      "$FW" fw blocks                   # last 30 access log lines
docker exec -it  "$FW" fw log                      # follow the live access log
```

All policy state lives on the `policy` volume, mounted at `/policy` inside the `firewall` container. The watcher process recompiles the ACL and reconfigures Squid within ~5 seconds of any change.

| File | Purpose |
|---|---|
| `/policy/allowlist.acl.perm` | Permanent allows — one domain per line. |
| `/policy/ttl.tsv` | Temporary allows — tab-separated `<epoch_expiry>\t<domain>`. |
| `/policy/allowlist.acl` | Compiled ACL read by Squid — **auto-generated, do not edit directly**. |
