# Claude Code Dev Container

A generic hardened Dev Container for running AI coding agents safely. Provides default-deny network isolation, project-scoped state, and non-root execution out of the box — then makes that sandbox comfortable to live in, with first-class support for several agent frameworks (Claude Code, opencode, GitHub Copilot CLI) and LLM providers (Anthropic direct, Anthropic API key / gateway, Azure AI Foundry, GitHub Copilot).

## Goal

**Security is the primary goal.** This container exists so that a misbehaving or compromised agent cannot reach anything outside the project:

1. **Blast-radius containment.** Limits what a running agent can touch to the project workspace and an explicit allowlist of network destinations — no host home directory, no cloud credentials, no SSH keys.

2. **Project isolation.** Each project gets its own container, caches, and session state. No cross-project bleed.

**Ease of use is a close second.** A sandbox nobody wants to work in doesn't get used, so the container is also built to be productive and framework-agnostic — without ever relaxing the security boundary above:

3. **Multiple agent frameworks, one container.** Claude Code, [opencode](#github-copilot-opencode), and the [GitHub Copilot CLI](#github-copilot-cli) are all installed and ready to run side by side.

4. **Pluggable LLM providers.** A single `use-*` switch ([`llm-switch.sh`](#devcontainerdevelopmentllm-switchsh)) routes `claude`/`opencode` across Anthropic direct, an Anthropic API key or gateway, and Azure AI Foundry; Copilot-backed models are available through opencode and the Copilot CLI.

5. **Comfortable out of the box.** A useful baseline of CLI tools, an auto-opening terminal, firewall-aware tooling that explains blocks instead of failing cryptically, and guidance for [adding your own tools](#adding-tools-to-the-development-container) and skills.

## Security measures

**Default-DENY outbound network via a separate firewall container.** The dev container (`development`) is on a Docker `internal: true` network with **no route to the internet**. The only egress path is a Squid proxy running in a sibling `firewall` container that enforces a domain allowlist, split into an always-on baseline plus toggleable [feature-sets](#configuring-the-allowlist-feature-sets) (see [.devcontainer/firewall/features/](.devcontainer/firewall/features)). Denied requests return a readable `403` whose body is a **firewall-aware plain-text page** explaining that the host is off the allowlist and how to add it — so AI tools (including ones with no project-prompt hook, like the Copilot CLI) surface actionable guidance instead of retrying a "connection failed". `CLAUDE.md` and `AGENTS.md` carry the same network-topology note for Claude Code and opencode. Tools that ignore `HTTP(S)_PROXY` fail closed (no route out), they don't bypass the firewall.

**Out-of-band management plane (QoL).** A third `control` container hosts the `allow`/`deny` commands, the policy volume, and the web dashboard. It sits on a separate network (`egress` only, never `internal`) and is therefore unreachable from `development`. The hard isolation is the network topology — `development` has no route to `control` regardless of what `control` runs. `control` is a convenience layer: the security would hold even if it were removed and the policy volume were edited directly. An agent inside `development` cannot modify its own allowlist.

**Domain-based filtering.** The allowlist is hostnames, not snapshotted IPs — resilient to CDN/Azure IP rotation. No periodic re-resolution needed.

**Azure browser callback ingress (localhost-only).** To support `az login` browser flow in-container, localhost ports `8400-8999` are published from host to `development`. The firewall only filters egress, so inbound publishes don't bypass it. Limited to `127.0.0.1` on the host.

**Non-root user, no sudo.** Container runs as `devuser` (UID 1000) with no sudo privileges whatsoever.

**Resource limits.** CPU (4 cores), memory (8 GB), PID (512) caps prevent a runaway agent from affecting the host.

**Read-only git identity.** `~/.gitconfig` is bind-mounted read-only — the agent cannot rewrite git hooks or other config.

**SSH key isolation (optional).** SSH agent forwarding is supported but disabled by default. When enabled, keys stay on the host and the container can only sign operations, never read key material. See the Caveats section for platform-specific setup.

**No Docker socket.** `/var/run/docker.sock` is not mounted. Mounting it is a one-line host root escalation.

**VS Code extensions are a trust boundary — vet them.** An extension is code that runs automatically, and the two execution locations have very different blast radii:
- **Workspace extensions** run *inside* this container as `devuser`, so they are subject to the firewall (they cannot reach a non-allowlisted host). But they auto-execute on attach and can read anything `devuser` can — `ANTHROPIC_API_KEY`, `~/.claude/settings.json`, your workspace — and a malicious one could tunnel that data out over an **allowlisted** domain (the marketplace, a CDN, or `github.com` if that feature-set is on). The firewall narrows the exfil channel; it does not close it.
- **UI / host extensions** run on the **host**, entirely outside this container and its firewall. A malicious host extension is a host compromise and is **not** contained by anything here.

Mitigations: pin a reviewed set in `devcontainer.json` (`customizations.vscode.extensions` — host-controlled and read-only in the container, so an in-container agent can't add to it); keep the allowlist minimal (disable [feature-sets](#configuring-the-allowlist-feature-sets) you don't use, to shrink the exfil surface); and treat `~/.vscode-server/extensions` as throwaway — it's on the writable layer, so a rebuild clears any extension dropped at runtime. The `/security-test` skill (Test 12) probes the in-container portion of this surface; host extensions remain your responsibility to vet.

**Project-scoped volumes.** All persistent state (Claude config, caches, history) lives in named Docker volumes prefixed with the project directory name. Separate projects = separate volumes.

## File guide

### `.devcontainer/devcontainer.json`
VS Code dev-container orchestration. Points at `docker-compose.yml`, selects `development` as the attach target, and wires the three lifecycle hooks: `initializeCommand` → [`initialize.sh`](#devcontainerinitializesh) (host), `postCreateCommand` → [`post-create.sh`](#devcontainerdevelopmentpost-createsh) (once), and `postStartCommand` → [`post-start.sh`](#devcontainerdevelopmentpost-startsh) (every start).

### `.devcontainer/initialize.sh`
Runs on the **host** before Compose starts. Writes `.devcontainer/.env` with project-scoped container/volume names and optional host-env passthrough (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN` — only emitted when set, so an empty value never masks a key persisted in the container). Sources `~/.devcontainer-secrets` if present (see [the host-secrets helper](#store-the-key-on-the-host-with-the-helper-script)).

### `.devcontainer/docker-compose.yml`
Defines the three services and two networks:
- `development` — the container VS Code attaches to. Internal-only network. All persistent state on per-project named volumes (`${LOCAL_WORKSPACE_FOLDER_BASENAME}-*`). Publishes `127.0.0.1:8400-8999` for `az login`. CPU/memory/PID limits set here. The `.devcontainer` mount is **fine-grained**: `development/` (the `.zshrc`, `llm-switch.sh`, and similar UX files) is writable so you can tweak the setup in-container, while the security-perimeter files (`Dockerfile`, `post-create.sh`, `post-start.sh`, `firewall/`, `control/`, `docker-compose.yml`, `devcontainer.json`, `.env`) stay individually read-only.
- `firewall` — Squid on `internal` + `egress`. The only path to the internet.
- `control` — hosts `allow`/`deny`; on `egress` only, not reachable from `development`.

### `.devcontainer/development/Dockerfile`
Image for the dev container (base `node:24-bookworm`). Installs a baseline of CLI tools (see [Adding tools](#adding-tools-to-the-development-container)), Azure CLI, GitHub CLI, non-root `devuser`, Claude Code, opencode, the GitHub Copilot CLI (`@github/copilot`), and `global-agent` (so Node's native `fetch`/`https` honour the proxy). Sets `HTTP(S)_PROXY=http://firewall:3128` and `NODE_OPTIONS=-r global-agent/bootstrap` image-wide.

### `.devcontainer/development/post-create.sh`
Runs **once** after first container creation. Generic hook for project setup (dependency install, first-run config — commented templates included). Registers `llm-switch.sh` in `~/.zshrc` and seeds `~/.claude/settings.json`.

### `.devcontainer/development/post-start.sh`
Runs on **every** container start (including after rebuilds). Symlinks `~/.claude.json` into the persistent `~/.claude` volume so Claude Code config survives rebuilds, re-applies the Azure CLI browser-login flag (`core.login_experience_v2=on`), and restores the active LLM provider from `~/.llm-provider` (or defaults to `use-anthropic` — Claude on an Anthropic subscription) so a deliberate provider switch sticks across restarts.

### `.devcontainer/development/llm-switch.sh`
Defines `use-anthropic-key` / `use-foundry` / `use-anthropic` / `llm-mode` shell commands for switching the active LLM provider. Each command configures both Claude Code (`~/.claude/settings.json`) and opencode (`~/.config/opencode/opencode.json`) so both tools stay in sync.

The **default is Claude on an Anthropic subscription** (`use-anthropic`, OAuth) — see [Choosing a provider](#choosing-a-provider) for the security rationale. `use-foundry` (Azure Entra) is the keyless alternative; API-key mode (`ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL`) is the static-credential fallback and must be selected explicitly with `use-anthropic-key`.

The chosen provider is recorded in `~/.llm-provider` and re-applied automatically in new terminals and after rebuilds (`post-start.sh`), so a deliberate switch sticks even though the container keeps `ANTHROPIC_API_KEY` in the environment. For OAuth that means the leaked key is actively unset in each new shell. **Note:** Claude Code builds the `/model` list once at startup from the active provider — restart `claude` after switching to refresh the available models (e.g. the larger set offered by the OAuth subscription).

### `.devcontainer/development/.zshrc` & `show-banner.sh`
`.zshrc` is the container shell config (writable, so you can tweak it in-container). `show-banner.sh` prints the AI-tools welcome banner (available agents + provider-switch commands); it is run by the auto-open terminal task just before it hands over to an interactive shell.

### `.vscode/tasks.json`
A `folderOpen` task ("Open terminal on attach") that auto-opens a focused `zsh` terminal in the container, prints the banner, then `exec`s a login shell. VS Code asks to "Allow Automatic Tasks" once. Scoped to Linux — a no-op when the folder is opened on a Windows/macOS host.

### `.devcontainer/firewall/`
Squid image: `squid.conf` (ACL + the firewall-aware `deny_info` error page), `features/` (the always-on `_baseline.list` plus one `.list` per toggleable feature-set), `build-acl.sh` (merges baseline + enabled features + manual + TTL into the live ACL), `ERR_FIREWALL_BLOCKED` (the plain-text page served on a blocked request), `entrypoint.sh`, `watcher.sh` (hot-reloads policy every 5s), `blockfeed.sh` (read-only HTTP feed of recent blocks on `:8099`), `fw` (management script — see [Manage the allowlist](#manage-the-allowlist-from-the-host)).

### `.devcontainer/control/`
Out-of-band management plane, unreachable from `development`. Holds the policy volume, the web dashboard (`dashboard.py`), and the management scripts it calls (`allow.sh`, `deny.sh`, `list_allows.sh`, `show_blocks.sh`, `tail_firewall.sh`). These scripts write to the same shared `policy` volume as the firewall container's `fw` script, so the dashboard and the CLI are always in sync.

### `.claude/skills/`
Five bundled productivity Agent Skills shared by all three agents — see [Bundled skills](#bundled-skills).

### `CLAUDE.md` & `AGENTS.md`
Project-level agent guides carrying the **firewall-awareness note** (the network topology and how to request allowlist additions), read automatically by Claude Code (`CLAUDE.md`) and opencode (`AGENTS.md`). Portable: copy into any project so its agents understand the default-deny network instead of misreading a blocked request as a connectivity failure.

### `tools/`
Host-side helper scripts. `setup-host-secrets.sh` persists `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` to `~/.devcontainer-secrets` so they survive rebuilds (see [Store the key on the host](#store-the-key-on-the-host-with-the-helper-script)); `test-opencode-providers.sh` verifies `opencode` completes a round-trip under both Anthropic auth modes.

## How to use

1. Copy `.devcontainer/` into your project root. Also worth copying:
   - `.vscode/tasks.json` — auto-opens a terminal on attach.
   - `.claude/skills/` — the [bundled skills](#bundled-skills).
   - `CLAUDE.md` / `AGENTS.md` — the firewall-awareness note for Claude Code / opencode (merge into your own if you already have these files).
   - `tools/setup-host-secrets.sh` — host-side API-key persistence (see [Store the key on the host](#store-the-key-on-the-host-with-the-helper-script)).
   - `.gitattributes` — forces `eol=lf` on `*.sh`; without it a Windows host can save the lifecycle/firewall scripts with CRLF and they fail inside the Linux container. If your repo already has one, just add the `*.sh text eol=lf` line.
   - Make sure your `.gitignore` keeps `*.env` out of git — `.devcontainer/.env` can hold your API key.
2. "Reopen in Container" from VS Code or Cursor, or run `devcontainer up --workspace-folder .`
3. First build: a few minutes (three images). Subsequent starts: seconds. **Default auth: Claude on an Anthropic subscription** (`use-anthropic`, OAuth) — selected out of the box; run `claude login` when prompted. See [Choosing a provider](#choosing-a-provider) for why this is the default and how to switch to Azure Foundry or a static API key.
4. A focused `zsh` terminal opens automatically when the workspace folder opens (VS Code asks to "Allow Automatic Tasks" once) and greets you with a banner of the available agents. Run `claude` (Claude Code), `opencode`, or `copilot` (GitHub Copilot CLI) in it.

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

docker exec      "$FW" fw feature list                     # feature-sets + their domains + on/off
docker exec      "$FW" fw feature on  azure                # enable a feature-set
docker exec      "$FW" fw feature off npm                  # disable a feature-set
```

Changes take effect within ~5s (the firewall watcher reloads Squid). Run these on the **host**, not inside the dev container — `development` is deliberately unable to reach the management plane.

### Web dashboard (localhost only)

A single-page dashboard is served by the `control` container at **<http://127.0.0.1:8088>**. It is bound to `127.0.0.1` only — the same localhost-only pattern as the Azure login ports — and is not reachable from inside `development`.

| Section | What it shows |
|---|---|
| **Live Traffic** | Real-time stream of every proxied request, colour-coded green (allowed) / red (denied). Collapsible; filter text persists across reloads. |
| **Feature sets** | One row per toggleable feature-set (`anthropic`, `github`, `npm`, …) with an **Enable**/**Disable** button and the domains it grants. A feature pulled in by another's dependency (e.g. `github` for `copilot`) is badged **via dep** and shows what requires it. |
| **Allowlist** | **Manual (permanent)** entries you added by hand, **Temporary** TTL entries (live countdown), and the read-only **Baseline (always on)** set. Each manual/temporary row has a **Remove** button. Domains granted by a feature-set live in the Feature sets card, not here. |
| **Recently Blocked** | Domains with at least one denied request, grouped by host and sorted by recency. One-click **Permanent** / **5m** / **15m** / **1h** and **Custom…** allow buttons per row. |

Every mutation from the dashboard writes to the same shared `policy` volume that the `fw` script modifies directly, so the CLI and the dashboard are always in sync.

### Configuring the allowlist (feature-sets)

The allowlist is split into a small always-on **baseline** plus named
**feature-sets** you toggle on or off. The baseline is only what's needed to
open and operate the dev container itself (VS Code server + marketplace, Debian/
Microsoft apt, a generic JS CDN); everything project-specific is a feature.

| Feature | Grants access to | Default |
|---|---|---|
| `anthropic` | Claude Code / Anthropic API (`api.anthropic.com`, `claude.ai`) | **on** |
| `github` | git, `gh`, GitHub package/skill installs | **on** |
| `npm` | npm / yarn registries | **on** |
| `opencode` | opencode's model catalogue (`models.dev`) | **on** |
| `copilot` | GitHub Copilot inference (`*.githubcopilot.com`); **depends on `github`** | off |
| `pypi` | Python package index | off |
| `golang` | Go module proxy + checksum DB | off |
| `azure` | Azure AI Foundry (Entra ID, ARM, Foundry portal, data plane) | off |
| `infosupport` | Info Support LLM gateway (test) | off |

Definitions live in `.devcontainer/firewall/features/*.list` (one file per
feature, domain-per-line, with an optional `# depends:` header). They are baked
read-only into the firewall image — adding or editing a feature is a maintainer
action (edit + rebuild the firewall), so a process inside the dev container
cannot grant itself new domains.

**Toggle a feature** (effective within ~5s, no rebuild):

```bash
docker exec "$FW" fw feature on  azure     # or use the control web UI
docker exec "$FW" fw feature off pypi
```

Enabling a feature transparently pulls in its dependencies (turning on `copilot`
also allows `github`'s domains, even if `github` is off). Manual `fw allow`
additions and TTL entries are kept separate from features; removing a
feature-granted domain with `fw deny` is refused and points you at
`fw feature off <name>`.

> **🔒 Maximise security — disable what you don't use.** The defaults enable
> `anthropic`, `github`, `npm`, and `opencode` (the API-key agentic tools and
> their common ecosystem). For the tightest egress surface, **turn off the
> agentic frameworks you don't run**
> — if you only use Claude Code, `fw feature off opencode`; if you only use
> opencode, `fw feature off anthropic`; enable `copilot` only when you actually
> use Copilot. Likewise leave `pypi` / `golang` / `azure` / `infosupport` off
> unless the project needs them. To reproduce the old "everything allowed"
> behaviour, enable every feature: `for f in anthropic github npm opencode copilot pypi golang azure infosupport; do docker exec "$FW" fw feature on $f; done`.

### See blocks from inside the dev container
- Each blocked request shows up as a `403` proxy error in your tools.
- Read-only recent-blocks feed: `curl -s http://firewall:8099`

## Choosing a provider

**Default: Claude on an Anthropic subscription (`use-anthropic`, OAuth).** This is what the container selects out of the box — no API key required and no long-lived secret on disk. Sign in once with `claude login` when prompted.

- Prefer Azure AI Foundry? → `use-foundry` + `az login` (Entra ID), or set `CLAUDE_CODE_USE_FOUNDRY=1` before opening the container. Also keyless: a short-lived Entra token instead of a static key.
- Using Copilot (via the [Copilot CLI](#github-copilot-cli) or [opencode](#github-copilot-opencode))? → already a browser **device-flow OAuth** login — no API key to manage.
- Reserve the [static Anthropic API key](#anthropic-api-key-static-key-fallback) for environments where none of the above is available. It is no longer auto-selected — run `use-anthropic-key` explicitly to opt in.

### Why a subscription / OAuth is the default

This container is hardened (default-deny egress, non-root, project-scoped state) precisely because an agentic coding tool runs partly-untrusted input — prompt injection from a web page, a malicious dependency, a poisoned file in the repo. The realistic threat is **an agent being steered into reading a credential off disk and exfiltrating it.** That reframes the question from "is my key encrypted" to "can the agent read a credential that stays valid after it leaks":

- **A static `ANTHROPIC_API_KEY` is the worst case.** It is long-lived (valid until you manually rotate it), and to feed all three tools it ends up in plaintext in *four* readable places: the process environment (`docker inspect`, `/proc/*/environ`), `.devcontainer/.env`, `~/.claude/settings.json`, and `~/.config/opencode/opencode.json`. Anything the agent can execute can `cat` it, and once leaked it keeps working.
- **An Anthropic subscription (`use-anthropic`, OAuth) carries no static key.** Auth is an OAuth credential scoped to your account and revocable from it, and `llm-switch.sh` actively *unsets* any container-wide `ANTHROPIC_API_KEY` in every new shell while you're in this mode, so a stray key can't silently win.
- **Entra (`az login`, Foundry) stores no static key either.** Auth is a short-lived token (~1h) tied to your Azure identity, refreshed on demand and revocable centrally by your org. A leaked token expires on its own.

The firewall already blocks most exfiltration routes, but not having a durable, plaintext, never-expiring secret on disk in the first place is the defense-in-depth that doesn't depend on the egress filter holding. Use the subscription (or Entra); fall back to a static key only when you must, and treat it as disposable (short rotation, never a key you wouldn't put on disk).

## Anthropic API key (static-key fallback)

> Prefer OAuth / Entra where available — see [Choosing a provider](#choosing-a-provider) for why. Use this path only when neither is an option.

When `ANTHROPIC_API_KEY` is exported on the host at the time you open the container, the dev container picks `use-anthropic-key` as the provider on first create. The key (and an optional `ANTHROPIC_BASE_URL`) is passed in via `initializeCommand` → `.devcontainer/.env` → the `development` service `environment` block in [docker-compose.yml](.devcontainer/docker-compose.yml). `.env` is gitignored, but the key is still readable by anything that can run `docker inspect` on the container — do not use a key you wouldn't put on disk.

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
llm-mode                                     # should print: Anthropic API key (base: ...)
echo "${ANTHROPIC_API_KEY:0:10}..."          # should print the prefix
grep ANTHROPIC_API_KEY ~/.claude/settings.json
```

If you set the key after the container was already created, run `use-anthropic-key` once in the container shell to rewrite `~/.claude/settings.json`.

### Store the key on the host with the helper script

Exporting `ANTHROPIC_API_KEY` in your shell or shell rc works, but it means the variable has to be present in the exact shell that launches VS Code every time. The helper script [`tools/setup-host-secrets.sh`](tools/setup-host-secrets.sh) makes that persistent:

```bash
bash tools/setup-host-secrets.sh
```

What it does:

- Prompts (with hidden input) for `ANTHROPIC_API_KEY` and an optional `ANTHROPIC_BASE_URL`. Re-running it preserves any value you leave blank, so it doubles as a rotation tool.
- Writes them to `~/.devcontainer-secrets` on the host with `chmod 600`. This file lives outside the repo and is never committed.
- Patches [`.devcontainer/initialize.sh`](.devcontainer/initialize.sh) (idempotently — it skips if already patched) to `source ~/.devcontainer-secrets` early. Because `initialize.sh` runs as the `initializeCommand` on every container start, the secrets are re-exported on the host side of `initialize.sh` for each rebuild — so the value flows into the container via the normal `initializeCommand → .env → docker-compose` passthrough without you having to keep it exported in your launching shell.

**Why it exists:** a full rebuild that removes the named Docker volume wipes `~/.claude/settings.json`, and a fresh login shell may not have `ANTHROPIC_API_KEY` exported. Storing the secret once on the host means the key is available on every rebuild. Note the default provider is now the Anthropic subscription (`use-anthropic`), so a stored key is **not** auto-selected — run `use-anthropic-key` once in the container to switch to it (the choice then persists via `~/.llm-provider`). After running the script once, just rebuild the container.

> Security note: `~/.devcontainer-secrets` holds the key in plaintext on the host (mode `600`). Anyone who can read your home directory or the Docker daemon can read it — same trust model as the named-volume storage below.

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

Azure AI Foundry is the **keyless alternative** to the default Anthropic-subscription provider — opt in with `use-foundry` (or set `CLAUDE_CODE_USE_FOUNDRY=1` before opening the container). Like the subscription default, it avoids a static key on disk: Entra (`az login`) authenticates with a short-lived, revocable token (see [Choosing a provider](#choosing-a-provider)). Update the resource values below to match your environment.

### 1. Firewall - add your resource endpoints to the allowlist

Azure access is the `azure` **feature-set** ([.devcontainer/firewall/features/azure.list](.devcontainer/firewall/features/azure.list)) — it groups Microsoft Entra ID, Azure Resource Manager, `ai.azure.com`, and the common Azure data-plane wildcards. It is **off by default**, so enable it first (see [Configuring the allowlist](#configuring-the-allowlist-feature-sets)):

```bash
docker exec "$FW" fw feature on azure
```

Then add your per-resource endpoints (find them in the Azure portal under your resource → Keys and Endpoint, or `az cognitiveservices account show --name <n> --resource-group <rg> --query "properties.endpoints" -o json`). Two ways to add:

```bash
# Temporary/iterating — applies within ~5s, no rebuild needed:
docker exec "$FW" fw allow YOUR-RESOURCE.services.ai.azure.com

# Permanent — add to the azure feature list and rebuild the firewall image:
#   1. add the line to .devcontainer/firewall/features/azure.list
#   2. docker compose -f .devcontainer/docker-compose.yml build firewall
#   3. Reopen in Container
```

Note: Squid's `dstdomain` ACL matches by hostname (not IP), so CDN/Azure IP rotation never breaks the allowlist. Wildcard entries (e.g. `.core.windows.net`) match all subdomains.

### 2. llm-switch.sh - verify Foundry defaults

Provider routing now lives in the in-shell switcher [`.devcontainer/development/llm-switch.sh`](.devcontainer/development/llm-switch.sh), not in `devcontainer.json`. Update the defaults near the top:

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

- `use-anthropic` — use the OAuth login flow (Claude subscription). Launches `claude login` on first use. **Preferred** — no static key on disk (see [Choosing a provider](#choosing-a-provider)).
- `use-anthropic-key` — use a direct Anthropic API key (static-key fallback). Requires `ANTHROPIC_API_KEY` (and optionally `ANTHROPIC_BASE_URL`) to be present in the container env — see [Anthropic API key (static-key fallback)](#anthropic-api-key-static-key-fallback) for host-side setup. Auto-selected on first create only when the key is set.

## GitHub Copilot (opencode)

If your organisation provides LLM access through a **GitHub Copilot** subscription (Pro, Pro+, Business, or Enterprise), you can use it inside the container with **opencode**, authenticated via GitHub's **browser device login** — no `GITHUB_TOKEN` or API key to manage. opencode stores its own credential in `~/.local/share/opencode/auth.json`.

> **Claude Code is _not_ supported on this backend.** Claude Code only speaks to Anthropic-compatible endpoints (Anthropic direct, Bedrock, Vertex, Foundry) and has no GitHub Copilot mode — the upstream request for a bearer-token gateway was closed as "not planned". Routing it through Copilot would require a reverse-engineered local proxy (a ToS gray area, and it loses extended thinking), so that path was deliberately dropped. Use **opencode** for Copilot, or one of the Anthropic providers for Claude Code.

### 1. Firewall allowlist

opencode's Copilot flow reaches a few domains the default-deny firewall must allow. They are split across two feature-sets — enable both (see [Configuring the allowlist](#configuring-the-allowlist-feature-sets)):

- `copilot` feature → `.githubcopilot.com` — Copilot inference. The leading-dot wildcard covers the individual, **business**, and enterprise endpoints (e.g. `api.business.githubcopilot.com`). It **depends on** `github`, so enabling `copilot` also allows device login / token exchange.
- `github` feature → `github.com` (device login) and `api.github.com` (Copilot token exchange) — on by default.
- `opencode` feature → `models.dev`, opencode's model catalogue — on by default.

```bash
FW="claude-$(basename "$PWD")-firewall"
docker exec "$FW" fw feature on copilot     # pulls in github automatically
```

`initialize.sh` and `docker-compose.yml` are unchanged — browser login needs no token passthrough.

### 2. Enable the Copilot feature on the running firewall

Toggling a feature takes effect within ~5s, no rebuild:

```bash
FW="claude-$(basename "$PWD")-firewall"
docker exec "$FW" fw feature on copilot     # .githubcopilot.com (+ github via dependency)
# opencode catalogue (models.dev) is the `opencode` feature, on by default.
```

### 3. Log in with the browser device flow

Inside the container, start opencode and connect Copilot:

```bash
opencode
```

Then in the opencode TUI:
1. Run `/connect` and choose **GitHub Copilot**.
2. opencode prints a one-time code and the URL `https://github.com/login/device`. Open it in your **host** browser, enter the code, and authorise (the browser runs on the host, so it has normal internet — only opencode's polling goes through the container firewall).
3. Run `/models` and pick a Copilot-backed model.

> The credential lives at `~/.local/share/opencode/auth.json`, which is **not** on a persisted volume — it survives container restarts but not a full rebuild. Re-run `/connect` after a rebuild.

### 4. Verify

```bash
# inside the container
echo "$HTTPS_PROXY"                                  # http://firewall:3128
curl -sS -o /dev/null -w '%{http_code}\n' https://api.business.githubcopilot.com   # 401/404 (reachable), not 000/403 (blocked)
opencode auth list                                   # shows a github-copilot credential
```

Then send a prompt in opencode against the selected Copilot model. If a call is blocked, check the firewall block feed from inside the container (`curl -s http://firewall:8099`) and allowlist any missing domain on the host with `fw allow`.

## GitHub Copilot CLI

The image also ships GitHub's GA agentic **Copilot CLI** (npm `@github/copilot`, command `copilot`) as a third agentic coding tool alongside `claude` and `opencode`. It plans, edits, and reviews across sessions, authenticated with your GitHub Copilot subscription via the same **browser device login** as the opencode flow above — no `GITHUB_TOKEN` or API key to manage.

> `copilot` is the GA agentic CLI, **not** the legacy `gh copilot` suggest/explain extension. It has its own auth and is independent of the `use-*` provider switch (which only routes `claude`/`opencode` over Anthropic-compatible endpoints).

### 1. Firewall allowlist — enable the `copilot` feature

The Copilot CLI uses the same domains as the opencode Copilot flow: `github.com/login/device` (device login), `api.github.com` (token exchange), and `*.githubcopilot.com` (inference). These are covered by the `copilot` feature-set (which depends on `github`); enable it once with `docker exec "$FW" fw feature on copilot` (see [Configuring the allowlist](#configuring-the-allowlist-feature-sets)). (Update-check / telemetry domains stay blocked unless a call genuinely requires them.)

### 2. Log in with the browser device flow

```bash
copilot
```

Then in the Copilot CLI:
1. Run `/login` (or `copilot login`). It prints a one-time code and the URL `https://github.com/login/device`.
2. Open that URL in your **host** browser, enter the code, and authorise (the browser runs on the host with normal internet — only the CLI's polling goes through the container firewall).

> The credential is stored under the home dir (XDG config), which is **not** on a persisted volume — it survives container restarts but not a full rebuild. Re-run `/login` after a rebuild (same caveat as opencode).

### 3. Verify

```bash
# inside the container
copilot --version                                    # confirms install on Node 24
echo "$HTTPS_PROXY"                                  # http://firewall:3128
```

Then run a small agentic task against a repo file and confirm a response. If a call is blocked, check the firewall block feed from inside the container (`curl -s http://firewall:8099`) and allowlist any genuinely-required domain on the host with `fw allow`.

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

## Adding tools to the development container

The image ships a baseline of common CLI tools, installed via the `apt-get install` block in [`.devcontainer/development/Dockerfile`](.devcontainer/development/Dockerfile):

- **Network diagnostics:** `ping` (`iputils-ping`), `traceroute`, `nc` (`netcat-openbsd`), `telnet`, plus `ip`/`dig` (`iproute2`, `dnsutils`).
- **Process & system:** `htop`, and `killall`/`pstree`/`fuser` (`psmisc`).
- **Files & data:** `tree`, `zip`/`unzip`, `sqlite3`.
- **Editor / search / build / runtime:** `vim`, `zsh`, `tmux`, `ripgrep`, `fd`, `fzf`, `jq`, `build-essential`, `python3`/`pipx`.

Because `devuser` has **no sudo access** inside the container, new *system* packages must be added to the Dockerfile and the container rebuilt:

1. Open `.devcontainer/development/Dockerfile`.
2. Add your package to the `apt-get install` block.
3. Rebuild: VS Code → Command Palette → *Dev Containers: Rebuild Container* (or `docker compose -f .devcontainer/docker-compose.yml build development`).

> The Dockerfile is bind-mounted **read-only** inside the container, so edit it from the **host** before rebuilding.

**Language-scoped tools without a rebuild (ephemeral).** Per-language package managers install into the container's writable layer, so they work from inside the container with no image change:

```sh
npm install -g <tool>     # installs to ~/.npm-global/bin (on PATH)
pipx install <tool>       # installs to ~/.local/bin
```

These install dirs are **not** named volumes: a runtime install survives a container *restart* but is **discarded on a full rebuild** — only the package *caches* (`~/.npm`, `~/.cache/pip`, …) are on named volumes, which just makes reinstalling fast. Treat runtime installs as throwaway; anything you want to keep belongs in the Dockerfile.

> **Why install dirs aren't persisted (security).** Keeping `~/.npm-global` and `~/.local` on the writable layer rather than on named volumes means a tool installed at runtime — including by an agent acting on partly-untrusted input — cannot outlive a rebuild or hide from the image. The image (a Dockerfile change + rebuild) stays the single source of truth for what executables exist; a rebuild restores a known-good toolset. Don't add named volumes for these paths.

The relevant package registry (npmjs.com, pypi.org, …) must be on the firewall allowlist first — see [Manage the allowlist from the host](#manage-the-allowlist-from-the-host).

### Bundled skills

The image ships **five productivity [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills)** under project-level `.claude/skills/` — chosen because they are broadly useful and stable enough to bake in. A single copy serves all three agents: Claude Code reads it natively, opencode via Claude-compat (on by default), and the Copilot CLI lists `.claude/skills/` among its project skill locations.

| Skill | What it does |
|---|---|
| `caveman` | Ultra-compressed replies — cuts token use ~75% by dropping filler while keeping technical accuracy. |
| `grill-me` | Interviews you about a plan or design until every branch of the decision is resolved. |
| `handoff` | Compacts the conversation into a handoff document another agent can pick up. |
| `teach` | Teaches a new skill or concept within the workspace. |
| `write-a-skill` | Scaffolds new Agent Skills with proper structure and progressive disclosure. |

For where to find **more** skills and how to add your own (skills are `SKILL.md` directories; Claude-only `/command` slash commands live in `.claude/commands/`), see the "Adding skills and tools" section in [`USAGE.md`](USAGE.md).

## Reducing permission prompts

By default Claude Code asks for confirmation before most tool actions. Because this container is already a hardened sandbox (default-deny network, non-root, no Docker socket, no host route — see [Security measures](#security-measures)), you can safely relax these prompts *inside* `/workspace` and let routine work flow without interruption, while still being asked about the handful of actions that are genuinely risky or expensive.

Create a personal, git-ignored `.claude/settings.local.json` in the repo root:

```jsonc
{
  "permissions": {
    // Run without prompting — safe inside the sandbox.
    "allow": [
      "Bash",
      "Read",
      "Edit",
      "Write"
    ],
    // Still prompt for these — they override the broad allows above
    // (an `ask` rule always wins over an `allow` rule).
    "ask": [
      // (1) Can break the container / are hard to undo:
      "Bash(rm -rf *)",
      "Bash(rm -fr *)",
      "Bash(rm -r *)",
      "Bash(git reset --hard *)",
      "Bash(git clean *)",
      "Bash(git push --force *)",
      "Bash(git push -f *)",
      "Bash(sudo *)",
      "Bash(npm install -g *)",
      "Bash(npm uninstall -g *)",
      "Bash(chmod -R *)",
      // (2) Spend significant tokens:
      "Agent",
      "Task",
      "Workflow"
    ]
  }
}
```

Tune the two lists to your own risk tolerance — add patterns you want to keep being asked about, or remove ones you don't.

**Why this is reasonable here.** The container has no route to the internet except the audited firewall proxy, runs as a non-root user with no sudo, has no Docker socket, and is resource-capped. A command run without a prompt still cannot reach a non-allowlisted domain, escalate to root, or touch the host. So the *blast radius* of an unprompted action is confined to the project files in `/workspace` — which are under git anyway.

**The risks — know what you're trading away.** Relaxing prompts removes a real safety net:

- **Workspace changes go unreviewed.** Any `Bash`, `Edit`, or `Write` runs without you seeing it first. A wrong command or a bad edit can still delete or corrupt your working-tree files. Commit often so git is your undo.
- **`ask` matches by command *prefix* only.** `rm -rf foo` prompts; `cd x && rm -rf foo` or `find . -delete` does **not** — the destructive part isn't at the start of the line. Treat the `ask` list as a speed-bump for the obvious cases, not an exhaustive guard.
- **Secrets in the working tree are readable.** Broad `Read`/`Bash` means a `.env` or token file under `/workspace` can be read into the model context without a prompt.
- **It does not weaken the container's own boundaries** (network, root, host) — those are enforced by Docker/Squid regardless of these settings. This only changes what *Claude* asks you about, not what the sandbox permits.

**Scope it to yourself.** `.claude/settings.local.json` is git-ignored, so it stays a personal choice and is never committed for the whole team. If you'd rather keep the prompts, simply don't create the file — the safe defaults apply. To dial it back at any time, delete the file or move specific patterns from `allow` to `ask`.

## Caveats

**Domain-based filtering, not IP-based.** Allowlist entries are hostnames. CDN/Azure IP rotation does not break anything. Wildcard entries (e.g. `.core.windows.net`) match all subdomains.

**Node tools need `global-agent`** to honour `HTTPS_PROXY`. The image installs it globally and preloads it via `NODE_OPTIONS=-r global-agent/bootstrap`, which covers `claude`, MCP servers, and the VS Code extension host. A Node script that explicitly clears `NODE_OPTIONS` (rare) will fail closed — that's correct behaviour, not a leak.

**Proxy-unaware tools fail closed.** `development` has no route to the internet outside the proxy. A tool that ignores `HTTP(S)_PROXY` cannot reach anything — there's no fallback path to bypass.

**SSH agent forwarding on Windows** requires `npiperelay` + the Windows OpenSSH Authentication Agent service. Until configured, use HTTPS + PAT or `gh auth login`. The SSH mount line in `docker-compose.yml` is commented out by default.

**macOS bind mount performance.** `node_modules`, `.venv`, and similar high-IOPS paths are on named volumes in this config. If you add new high-write paths, follow the same pattern.

**Allowlist policy persists.** It lives on the `policy` Docker volume and survives container restarts. To change which domains a feature-set grants, edit the relevant `.devcontainer/firewall/features/*.list` and rebuild the firewall image; toggle feature-sets on/off with `docker exec "$FW" fw feature on|off <name>`; use `docker exec "$FW" fw allow|deny` for live one-off edits.

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
| `/policy/features.defs/` | Feature-set definitions, refreshed from the baked firewall image on every start (image is source of truth). |
| `/policy/features.state` | Which feature-sets are on/off — `<name>=on\|off` per line. Written by `fw feature` / the control UI. |
| `/policy/allowlist.acl.perm` | Manual permanent allows (`fw allow`) — one domain per line. Starts empty. |
| `/policy/ttl.tsv` | Temporary allows — tab-separated `<epoch_expiry>\t<domain>`. |
| `/policy/allowlist.acl` | Compiled ACL read by Squid (baseline + enabled features + manual + TTL) — **auto-generated, do not edit directly**. |
