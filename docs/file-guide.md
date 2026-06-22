# File guide

### `.devcontainer/devcontainer.json`
VS Code dev-container orchestration. Points at `docker-compose.yml`, selects `development` as the attach target, and wires the three lifecycle hooks: `initializeCommand` → [`initialize.sh`](#devcontainerinitializesh) (host), `postCreateCommand` → [`post-create.sh`](#devcontainerdevelopmentpost-createsh) (once), and `postStartCommand` → [`post-start.sh`](#devcontainerdevelopmentpost-startsh) (every start).

### `.devcontainer/initialize.sh`
Runs on the **host** before Compose starts. Writes `.devcontainer/.env` with project-scoped container/volume names and optional host-env passthrough (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN` — only emitted when set, so an empty value never masks a key persisted in the container). Sources `~/.devcontainer-secrets` if present (see [store the key on the host with the helper script](providers.md#store-the-key-on-the-host-with-the-helper-script)).

### `.devcontainer/docker-compose.yml`
Defines the three services and two networks:
- `development` — the container VS Code attaches to. Internal-only network. All persistent state on per-project named volumes (`${LOCAL_WORKSPACE_FOLDER_BASENAME}-*`). Publishes `127.0.0.1:8400-8999` for `az login`. CPU/memory/PID limits set here. The `.devcontainer` mount is **fine-grained**: `development/` (the `.zshrc`, `llm-switch.sh`, and similar UX files) is writable so you can tweak the setup in-container, while the security-perimeter files (`Dockerfile`, `post-create.sh`, `post-start.sh`, `firewall/`, `control/`, `docker-compose.yml`, `devcontainer.json`, `.env`) stay individually read-only.
- `firewall` — Squid on `internal` + `egress`. The only path to the internet.
- `control` — hosts `allow`/`deny`; on `egress` only, not reachable from `development`.

### `.devcontainer/development/Dockerfile`
Image for the dev container (base `node:24-bookworm`). Installs a baseline of CLI tools (see [Adding tools](operations.md#adding-tools-to-the-development-container)), Azure CLI, GitHub CLI, non-root `devuser`, Claude Code, opencode, the GitHub Copilot CLI (`@github/copilot`), and `global-agent` (so Node's native `fetch`/`https` honour the proxy). Sets `HTTP(S)_PROXY=http://firewall:3128` and `NODE_OPTIONS=-r global-agent/bootstrap` image-wide.

### `.devcontainer/development/post-create.sh`
Runs **once** after first container creation. Generic hook for project setup (dependency install, first-run config — commented templates included). Registers `llm-switch.sh` in `~/.zshrc` and seeds `~/.claude/settings.json`.

### `.devcontainer/development/post-start.sh`
Runs on **every** container start (including after rebuilds). Symlinks `~/.claude.json` into the persistent `~/.claude` volume so Claude Code config survives rebuilds, re-applies the Azure CLI browser-login flag (`core.login_experience_v2=on`), and restores the active LLM provider from `~/.llm-provider` (or defaults to `use-anthropic` — Claude on an Anthropic subscription) so a deliberate provider switch sticks across restarts.

### `.devcontainer/development/llm-switch.sh`
Defines `use-anthropic-key` / `use-foundry` / `use-anthropic` / `llm-mode` shell commands for switching the active LLM provider. Each command configures both Claude Code (`~/.claude/settings.json`) and opencode (`~/.config/opencode/opencode.json`) so both tools stay in sync.

The **default is Claude on an Anthropic subscription** (`use-anthropic`, OAuth) — see [Choosing a provider](providers.md#choosing-a-provider) for the security rationale. `use-foundry` (Azure Entra) is the keyless alternative; API-key mode (`ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL`) is the static-credential fallback and must be selected explicitly with `use-anthropic-key`.

The chosen provider is recorded in `~/.llm-provider` and re-applied automatically in new terminals and after rebuilds (`post-start.sh`), so a deliberate switch sticks even though the container keeps `ANTHROPIC_API_KEY` in the environment. For OAuth that means the leaked key is actively unset in each new shell. **Note:** Claude Code builds the `/model` list once at startup from the active provider — restart `claude` after switching to refresh the available models (e.g. the larger set offered by the OAuth subscription).

### `.devcontainer/development/.zshrc` & `show-banner.sh`
`.zshrc` is the container shell config (writable, so you can tweak it in-container). `show-banner.sh` prints the AI-tools welcome banner (available agents + provider-switch commands); it is run by the auto-open terminal task just before it hands over to an interactive shell.

### `.vscode/tasks.json`
A `folderOpen` task ("Open terminal on attach") that auto-opens a focused `zsh` terminal in the container, prints the banner, then `exec`s a login shell. VS Code asks to "Allow Automatic Tasks" once. Scoped to Linux — a no-op when the folder is opened on a Windows/macOS host.

### `.devcontainer/firewall/`
Squid image: `squid.conf` (ACL + the firewall-aware `deny_info` error page), `features/` (the always-on `_baseline.list` plus one `.list` per built-in toggleable feature-set), `build-acl.sh` (merges baseline + enabled features + manual + TTL into the live ACL; scans both the built-in `features.defs/` and the user-created `features.d/` directories), `ERR_FIREWALL_BLOCKED` (the plain-text page served on a blocked request), `entrypoint.sh`, `watcher.sh` (hot-reloads policy every 5s), `blockfeed.sh` (read-only HTTP feed of recent blocks on `:8099`), `fw` (management script — see [Manage the allowlist](allowlist.md#manage-the-allowlist-from-the-host), including `fw feature create/edit/delete` for user-defined feature-sets).

### `.devcontainer/control/`
Out-of-band management plane, unreachable from `development`. Holds the policy volume, the web dashboard (`dashboard.py`), and the management scripts it calls (`allow.sh`, `deny.sh`, `feature.sh`, `list_allows.sh`, `show_blocks.sh`, `tail_firewall.sh`). These scripts write to the same shared `policy` volume as the firewall container's `fw` script, so the dashboard and the CLI are always in sync. User-defined feature-sets created via the dashboard or CLI are stored at `/policy/features.d/` on the `policy` volume and persist across container restarts.

### `.claude/skills/`
Six bundled Agent Skills shared by all three agents — see [Bundled skills](operations.md#bundled-skills).

### `CLAUDE.md` & `AGENTS.md`
Project-level agent guides carrying the **firewall-awareness note** (the network topology and how to request allowlist additions), read automatically by Claude Code (`CLAUDE.md`) and opencode (`AGENTS.md`). Portable: copy into any project so its agents understand the default-deny network instead of misreading a blocked request as a connectivity failure.

### `tools/`
Host-side helper scripts. `setup-host-secrets.sh` persists `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` to `~/.devcontainer-secrets` so they survive rebuilds (see [Store the key on the host](providers.md#store-the-key-on-the-host-with-the-helper-script)); `test-opencode-providers.sh` verifies `opencode` completes a round-trip under both Anthropic auth modes.
