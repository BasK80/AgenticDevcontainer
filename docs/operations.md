# Operations

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

The image ships a baseline of common CLI tools, installed via the `apt-get install` block in [`.devcontainer/development/Dockerfile`](../.devcontainer/development/Dockerfile):

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

The relevant package registry (npmjs.com, pypi.org, …) must be on the firewall allowlist first — see [Manage the allowlist from the host](allowlist.md#manage-the-allowlist-from-the-host).

## Bundled skills

The image ships **five bundled [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills)** under project-level `.claude/skills/` — four general-purpose productivity skills plus one security-validation skill, all broadly useful and stable enough to bake in. A single copy serves all three agents: Claude Code reads it natively, opencode via Claude-compat (on by default), and the Copilot CLI lists `.claude/skills/` among its project skill locations.

| Skill | What it does |
|---|---|
| `caveman` | Ultra-compressed replies — cuts token use ~75% by dropping filler while keeping technical accuracy. |
| `grill-me` | Interviews you about a plan or design until every branch of the decision is resolved. |
| `handoff` | Compacts the conversation into a handoff document another agent can pick up. |
| `write-a-skill` | Scaffolds new Agent Skills with proper structure and progressive disclosure. |
| `security-test` | Adversarial pentest of the container perimeter — runs escape / exfiltration / tamper probes from inside the container and reports HELD (blocked = good) / BYPASS (finding) per test. Trigger with `/security-test` (or "run the pentest"). See [Validating the perimeter](security.md#validating-the-perimeter). |

> `caveman`, `grill-me`, `handoff`, and `write-a-skill` were created by [Matt Pocock](https://github.com/mattpocock).

For where to find **more** skills and how to add your own (skills are `SKILL.md` directories; Claude-only `/command` slash commands live in `.claude/commands/`), see the "Adding skills and tools" section in [`USAGE.md`](../USAGE.md).

## Reducing permission prompts

By default Claude Code asks for confirmation before most tool actions. Because this container is already a hardened sandbox (default-deny network, non-root, no Docker socket, no host route — see [Security measures](security.md)), you can safely relax these prompts *inside* `/workspace` and let routine work flow without interruption, while still being asked about the handful of actions that are genuinely risky or expensive.

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

## Cleanup

```bash
# Stop and remove all three containers for this project:
docker compose -f .devcontainer/docker-compose.yml down -v

# Or by name (replace YOURPROJECT with your folder basename):
docker rm -f $(docker ps -aq --filter "name=agentic-YOURPROJECT")
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
> docker volume create agentic-YOURPROJECT-policy
> ```
> Replace `YOURPROJECT` with your folder basename.

The web dashboard at `:8088` will no longer be available. The `fw` script inside the firewall container remains fully functional — use it directly:

### Managing the firewall without the control container

```bash
# Set a shell variable for convenience (run on the host):
FW="agentic-$(basename "$PWD")-firewall"

docker exec      "$FW" fw allow example.com       # permanent allow
docker exec      "$FW" fw allow example.com 300   # temporary allow, 300s TTL
docker exec      "$FW" fw deny  example.com        # remove an allow (re-block)
docker exec      "$FW" fw list                     # current compiled allowlist
docker exec      "$FW" fw blocks                   # last 30 access log lines
docker exec -it  "$FW" fw log                      # follow the live access log
docker exec      "$FW" fw feature list             # all features, their state and domains
docker exec      "$FW" fw feature on  azure        # enable a built-in feature-set
docker exec      "$FW" fw feature off npm          # disable a built-in feature-set
docker exec      "$FW" fw feature show npm         # print raw .list file for a feature
docker exec      "$FW" fw feature create mycdn \
  -d "My CDN" --domain cdn.example.com             # create a user-defined feature (auto-enabled)
docker exec      "$FW" fw feature edit mycdn \
  --domain cdn.example.com \
  --domain assets.example.com                      # edit a user-defined feature (full replacement)
docker exec      "$FW" fw feature delete mycdn     # delete a user-defined feature
```

All policy state lives on the `policy` volume, mounted at `/policy` inside the `firewall` container. The watcher process recompiles the ACL and reconfigures Squid within ~5 seconds of any change.

| File | Purpose |
|---|---|
| `/policy/features.defs/` | Built-in feature-set definitions, refreshed from the baked firewall image on every start (image is source of truth). |
| `/policy/features.d/` | User-created feature-set definitions (`<name>.list`), on the shared `policy` volume. Persist across restarts; created/edited/deleted via `fw feature create/edit/delete` or the web UI. |
| `/policy/features.state` | Which feature-sets are on/off — `<name>=on\|off` per line. Written by `fw feature` / the control UI. |
| `/policy/allowlist.acl.perm` | Manual permanent allows (`fw allow`) — one domain per line. Starts empty. |
| `/policy/ttl.tsv` | Temporary allows — tab-separated `<epoch_expiry>\t<domain>`. |
| `/policy/allowlist.acl` | Compiled ACL read by Squid (baseline + enabled features + manual + TTL) — **auto-generated, do not edit directly**. |
