# LLM providers

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

When `ANTHROPIC_API_KEY` is exported on the host at the time you open the container, the dev container picks `use-anthropic-key` as the provider on first create. The key (and an optional `ANTHROPIC_BASE_URL`) is passed in via `initializeCommand` → `.devcontainer/.env` → the `development` service `environment` block in [docker-compose.yml](../.devcontainer/docker-compose.yml). `.env` is gitignored, but the key is still readable by anything that can run `docker inspect` on the container — do not use a key you wouldn't put on disk.

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

Exporting `ANTHROPIC_API_KEY` in your shell or shell rc works, but it means the variable has to be present in the exact shell that launches VS Code every time. The helper script [`tools/setup-host-secrets.sh`](../tools/setup-host-secrets.sh) makes that persistent:

```bash
bash tools/setup-host-secrets.sh
```

What it does:

- Prompts (with hidden input) for `ANTHROPIC_API_KEY` and an optional `ANTHROPIC_BASE_URL`. Re-running it preserves any value you leave blank, so it doubles as a rotation tool.
- Writes them to `~/.devcontainer-secrets` on the host with `chmod 600`. This file lives outside the repo and is never committed.
- Patches [`.devcontainer/initialize.sh`](../.devcontainer/initialize.sh) (idempotently — it skips if already patched) to `source ~/.devcontainer-secrets` early. Because `initialize.sh` runs as the `initializeCommand` on every container start, the secrets are re-exported on the host side of `initialize.sh` for each rebuild — so the value flows into the container via the normal `initializeCommand → .env → docker-compose` passthrough without you having to keep it exported in your launching shell.

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
- The host-side passthrough only sets the var when **non-empty** on the host (see [initialize.sh](../.devcontainer/initialize.sh)). If the host has no `ANTHROPIC_API_KEY`, the container starts without it set, and the value from `~/.claude/settings.json` is the source of truth.
- The key is stored plaintext in the named volume. Anyone with access to the host Docker daemon can read it (`docker run --rm -v ${PROJECT}-claude:/c alpine cat /c/settings.json`).
- To rotate, just re-run `use-anthropic-key` with a new value exported in the current shell.

## Azure AI Foundry overlay

Azure AI Foundry is the **keyless alternative** to the default Anthropic-subscription provider — opt in with `use-foundry` (or set `CLAUDE_CODE_USE_FOUNDRY=1` before opening the container). Like the subscription default, it avoids a static key on disk: Entra (`az login`) authenticates with a short-lived, revocable token (see [Choosing a provider](#choosing-a-provider)). Update the resource values below to match your environment.

### 1. Firewall - add your resource endpoints to the allowlist

Azure access is the `azure` **feature-set** ([.devcontainer/firewall/features/azure.list](../.devcontainer/firewall/features/azure.list)) — it groups Microsoft Entra ID, Azure Resource Manager, `ai.azure.com`, and the common Azure data-plane wildcards. It is **off by default**, so enable it first (see [Configuring the allowlist](allowlist.md#configuring-the-allowlist-feature-sets)):

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

Provider routing now lives in the in-shell switcher [`.devcontainer/development/llm-switch.sh`](../.devcontainer/development/llm-switch.sh), not in `devcontainer.json`. Update the defaults near the top:

```bash
: "${ANTHROPIC_FOUNDRY_RESOURCE:=YOUR-RESOURCE-NAME}"
: "${ANTHROPIC_DEFAULT_SONNET_MODEL:=claude-sonnet-4-6}"
: "${ANTHROPIC_DEFAULT_OPUS_MODEL:=claude-opus-4-6}"
: "${ANTHROPIC_DEFAULT_HAIKU_MODEL:=claude-haiku-4-5}"
```

These are written into `~/.claude/settings.json` whenever you run `use-foundry`.

### 3. post-create.sh - verify settings writer and az login mode

[`.devcontainer/development/post-create.sh`](../.devcontainer/development/post-create.sh) writes `~/.claude/settings.json` with Foundry env settings on first create and sets Azure CLI to browser login mode (`core.login_experience_v2=on`) when Foundry is enabled.

Additionally, `postStartCommand` in [`devcontainer.json`](../.devcontainer/devcontainer.json) reapplies the same Azure CLI setting on each container start as a self-heal for existing containers.

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
docker ps --filter "name=agentic-YOURPROJECT" --format "{{.Names}}\t{{.Ports}}"
```

Expected: three containers (`-development`, `-firewall`, `-control`) and the `development` container should show `127.0.0.1:8400-8999->8400-8999/tcp` (default; the exact per-project range comes from `DEV_PORT_BASE`/`DEV_PORT_END` in `.devcontainer/.env`).

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

opencode's Copilot flow reaches a few domains the default-deny firewall must allow. They are split across two feature-sets — enable both (see [Configuring the allowlist](allowlist.md#configuring-the-allowlist-feature-sets)):

- `copilot` feature → `.githubcopilot.com` — Copilot inference. The leading-dot wildcard covers the individual, **business**, and enterprise endpoints (e.g. `api.business.githubcopilot.com`). It **depends on** `github`, so enabling `copilot` also allows device login / token exchange.
- `github` feature → `github.com` (device login) and `api.github.com` (Copilot token exchange) — on by default.
- `opencode` feature → `models.dev`, opencode's model catalogue — on by default.

```bash
FW="agentic-$(basename "$PWD")-firewall"
docker exec "$FW" fw feature on copilot     # pulls in github automatically
```

`initialize.sh` and `docker-compose.yml` are unchanged — browser login needs no token passthrough.

### 2. Enable the Copilot feature on the running firewall

Toggling a feature takes effect within ~5s, no rebuild:

```bash
FW="agentic-$(basename "$PWD")-firewall"
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

The Copilot CLI uses the same domains as the opencode Copilot flow: `github.com/login/device` (device login), `api.github.com` (token exchange), and `*.githubcopilot.com` (inference). These are covered by the `copilot` feature-set (which depends on `github`); enable it once with `docker exec "$FW" fw feature on copilot` (see [Configuring the allowlist](allowlist.md#configuring-the-allowlist-feature-sets)). (Update-check / telemetry domains stay blocked unless a call genuinely requires them.)

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
