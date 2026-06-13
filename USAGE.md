# Quick Start (≈ 15 min setup)

## Choosing your LLM provider

The dev container supports three ways to run Claude. Pick one before you start:

| Provider | What you need | Setup details |
|---|---|---|
| **Anthropic API key** (direct or via a custom gateway) | An API key (`sk-ant-...`) and optionally a custom `ANTHROPIC_BASE_URL` | Steps 1–5 below |
| **Azure AI Foundry** | Access to an Azure AI Foundry resource | Steps 1–2 and 4, then see [README — Azure AI Foundry overlay](README.md#azure-ai-foundry-overlay) |
| **Claude subscription (OAuth)** | A Claude.ai subscription | Steps 1–2 and 4, then run `use-anthropic` inside the container |

> **Steps 3 and the firewall-hostname section of step 5 only apply to the Anthropic API key path.** If you are using Azure Foundry or the OAuth subscription flow, skip those parts and follow the README instead.

For the **Anthropic API key** path, you will also need:

- An **API key** (looks like `sk-ant-...`).
- Optionally, a custom **API base URL** (e.g. `https://your-gateway.example.com`) if you route through a gateway.

The dev container blocks all outbound traffic by default and only allows a small list of hostnames. If you use a custom gateway hostname, it must be added to the allowlist — step 5 below.

---

## 1. Install the prerequisites

### macOS (easiest path: Docker Desktop)

1. Install **Docker Desktop**: <https://www.docker.com/products/docker-desktop/> — open it once and wait until the whale icon shows "Docker Desktop is running".
2. Install **VS Code**: <https://code.visualstudio.com/>
3. In VS Code, install the **Dev Containers** extension (id: `ms-vscode-remote.remote-containers`).
4. Install **git** if you don't have it: `xcode-select --install`.

### Windows + WSL2 + Rancher Desktop

1. Make sure **WSL2** is installed with an Ubuntu distro. In PowerShell (admin): `wsl --install -d Ubuntu`, then reboot if prompted.
2. Install **Rancher Desktop**: <https://rancherdesktop.io/>
   - On first launch, in **Preferences → Container Engine**, select **dockerd (moby)** (not containerd).
   - In **Preferences → WSL → Integrations**, enable the toggle for your Ubuntu distro.
   - Wait until the status bar at the bottom says it's ready.
3. Install **VS Code**: <https://code.visualstudio.com/> — during install, leave "Add to PATH" checked.
4. In VS Code, install these two extensions:
   - **WSL** (`ms-vscode-remote.remote-wsl`)
   - **Dev Containers** (`ms-vscode-remote.remote-containers`)
5. Open your Ubuntu shell (Start menu → "Ubuntu") and verify Docker works inside WSL:
   ```bash
   docker run --rm hello-world
   ```
   You should see a "Hello from Docker!" message.

---

## 2. Get the code

**On Windows, the project must live inside the WSL file system, not under `/mnt/c/` or any other Windows-mounted drive.** Docker Desktop and Rancher Desktop have severe I/O performance issues and occasional bind-mount failures when the source tree is on a Windows path. Use a directory under your WSL home instead, e.g. `~/projects/`.

Open your **Ubuntu (WSL)** shell (on macOS, open **Terminal**) and unzip or clone into WSL:

```bash
# Option A — clone from git
cd ~
mkdir -p projects && cd projects
git clone <REPO_URL> agentic-devcontainer
cd agentic-devcontainer

# Option B — zip file
# Copy the zip into WSL first (from PowerShell or Explorer → \\wsl.localhost\Ubuntu\home\<you>\)
cd ~
mkdir -p projects && cd projects
unzip /path/to/agentic-devcontainer.zip
cd agentic-devcontainer
```

> **Do not place the folder under `/mnt/c/`, `/mnt/d/`, or any Windows-mounted path.** If you accidentally unzipped there, move it: `mv /mnt/c/Users/you/Downloads/agentic-devcontainer ~/projects/`

---

## 3. Export the API key _(API key path only — skip if using Foundry or OAuth)_

In the **same shell** you'll use to launch VS Code:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."                          # your Anthropic API key
export ANTHROPIC_BASE_URL="https://your-gateway.example.com"   # only needed for a custom gateway
```

Then launch VS Code from that same shell so it inherits the variables:

```bash
code .
```

> **Why from the shell?** Setting them in `.bashrc`/`.zshrc` also works, but you must then fully quit and reopen VS Code so it picks them up.

**Recommended (persistent, survives rebuilds):** instead of exporting in every shell, run the helper once on the host:

```bash
bash tools/setup-host-secrets.sh
```

It prompts for `ANTHROPIC_API_KEY` (and optional `ANTHROPIC_BASE_URL`), stores them in `~/.devcontainer-secrets` (mode `600`, never committed), and patches `.devcontainer/initialize.sh` to source that file on every container start. After running it, just rebuild the container — no need to keep the variables exported in your launching shell. See [README — store the key on the host with the helper script](README.md#store-the-key-on-the-host-with-the-helper-script).

For other setup methods (including Windows PowerShell), see [README — Anthropic API key](README.md#anthropic-api-key-default-provider).

---

## 4. Open in the dev container

In VS Code:

1. Press **F1** (or `Ctrl+Shift+P` / `Cmd+Shift+P`).
2. Run **Dev Containers: Reopen in Container**.
3. First build takes **3–8 minutes** (three images get built). Subsequent starts are seconds.

When the bottom-left of VS Code shows `Dev Container: claude-agentic-devcontainer`, you're in.

---

## 5. Run Claude (or opencode)

Open a terminal in VS Code (`` Ctrl+` ``) — this terminal is **inside** the container. Then:

```bash
llm-mode      # prints the active provider
claude           # starts Claude Code
opencode         # starts opencode (alternative agentic coding framework)
```

Both `claude` and `opencode` share the same provider config — switching with `use-anthropic-key`, `use-foundry`, or `use-anthropic` updates both tools at once.

If the wrong provider is active, switch it with one of:

```bash
use-anthropic-key   # Anthropic API key (requires ANTHROPIC_API_KEY in the container env)
use-foundry         # Azure AI Foundry (requires az login first — see README)
use-anthropic       # Claude subscription / OAuth login flow
```

> **Restart `claude` after switching.** The `/model` picker is built once, when `claude` starts, from the active provider — it does **not** refresh inside a running session. After a `use-*` switch, exit (`/exit` or Ctrl+C) and relaunch `claude` so it re-derives the available models (e.g. the larger set offered by the OAuth subscription).

> **Your choice persists.** Each `use-*` command records the provider in `~/.llm-provider`. New terminals and container rebuilds re-apply it automatically — so an OAuth switch sticks even though the container keeps `ANTHROPIC_API_KEY` in the environment. Already-open shells won't pick up the change until reopened.

For **Foundry**: after switching, run `az login` before starting `claude`. Azure tokens expire after ~1 hour of inactivity; re-run `az login` if you see auth errors.

**Custom gateway only:** if your `ANTHROPIC_BASE_URL` points to a hostname not already in the allowlist, add it from your host shell before starting:

```bash
FW="claude-$(basename "$PWD")-firewall"
docker exec "$FW" fw allow your-gateway.example.com
```

That's it — try a prompt like `list the files in this repo`.

---

## Troubleshooting

**"403" or "connection refused" when Claude tries to call the API** _(API key / custom gateway path)_
The gateway hostname isn't in the firewall allowlist. From your **host** shell (not inside the container), in the repo root:

```bash
FW="claude-$(basename "$PWD")-firewall"
docker exec "$FW" fw blocks                              # see what got blocked
docker exec "$FW" fw allow <hostname>                    # add it; takes effect within ~5 seconds
docker exec "$FW" fw list                                # confirm it's there
```

**`llm-mode` shows the wrong provider** _(API key path)_
Inside the container:
```bash
echo "${ANTHROPIC_API_KEY:0:10}..."    # should print sk-ant-...
use-anthropic-key                       # rewrite the settings file
```
If `ANTHROPIC_API_KEY` is empty inside the container, the host shell that launched VS Code didn't have it exported. Quit VS Code, redo step 3, and reopen.

**Azure auth errors or `az login` hangs** _(Foundry path)_
See [README — Azure AI Foundry overlay](README.md#azure-ai-foundry-overlay) for the full authentication flow and debug steps.

**Windows: `code .` doesn't open / opens the wrong VS Code**
You're probably running it from PowerShell instead of WSL. Always launch from your **Ubuntu (WSL)** shell so VS Code uses the WSL-side files and Docker socket.

**Windows: `docker` command not found in WSL**
Rancher Desktop's WSL integration is off. Open Rancher Desktop → Preferences → WSL → Integrations → enable your Ubuntu distro, then open a fresh Ubuntu shell.

**Container build fails on `apt-get update`**
Your network blocks Debian mirrors. Retry once; if it persists, contact whoever gave you the repo.

---

## Cleanup when you're done

From your host shell in the repo root:

```bash
docker compose -f .devcontainer/docker-compose.yml down -v
```

This stops all three containers and removes the named volumes (Claude session state, caches). The images stay cached for next time — remove them with `docker image prune -a` if you want a full reset.
