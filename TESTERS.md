# Tester Quick Start (≈ 15 min setup)

You'll get from your contact:

- A **repo link** (git URL or zip).
- An **API base URL** (e.g. `https://your-gateway.example.com`).
- An **API key** (looks like `sk-ant-...`).

The dev container blocks all outbound traffic by default and only allows a small list of hostnames. Your gateway hostname must be added to that allowlist — step 4 below.

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

Open a shell — **Terminal** on macOS, or your **Ubuntu (WSL)** shell on Windows — and clone:

```bash
git clone <REPO_URL_FROM_YOUR_CONTACT> agentic-devcontainer
cd agentic-devcontainer
```

(If you got a zip, unzip it and `cd` into the folder instead.)

---

## 3. Export the API key and base URL on the host

In the **same shell** you'll use to launch VS Code:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."           # the key your contact gave you
export ANTHROPIC_BASE_URL="https://your-gateway.example.com"   # the URL your contact gave you
```

Then launch VS Code from that same shell so it inherits the variables:

```bash
code .
```

> **Why from the shell?** Setting them in `.bashrc`/`.zshrc` also works, but you must then fully quit and reopen VS Code so it picks them up.

---

## 4. Open in the dev container

In VS Code:

1. Press **F1** (or `Ctrl+Shift+P` / `Cmd+Shift+P`).
2. Run **Dev Containers: Reopen in Container**.
3. First build takes **3–8 minutes** (three images get built). Subsequent starts are seconds.

When the bottom-left of VS Code shows `Dev Container: claude-agentic-devcontainer`, you're in.

---

## 5. Run Claude

Open a terminal in VS Code (`` Ctrl+` ``) — this terminal is **inside** the container. Then:

```bash
claude-mode      # should print: Anthropic API key (base: https://your-gateway.example.com)
claude           # starts Claude Code
```

If `claude-mode` shows the wrong provider, run `use-anthropic-key` once and try again.

That's it — try a prompt like `list the files in this repo`.

---

## Troubleshooting

**"403" or "connection refused" when Claude tries to call the API**
The gateway hostname isn't in the firewall allowlist. From your **host** shell (not inside the container), in the repo root:

```bash
./tools/fw blocks                            # see what got blocked
./tools/fw allow <hostname>                  # add it; takes effect within ~5 seconds
./tools/fw list                              # confirm it's there
```

**`claude-mode` says `unset` or shows Foundry / OAuth**
Inside the container:
```bash
echo "${ANTHROPIC_API_KEY:0:10}..."    # should print sk-ant-...
use-anthropic-key                       # rewrite the settings file
```
If `ANTHROPIC_API_KEY` is empty inside the container, the host shell that launched VS Code didn't have it exported. Quit VS Code, redo step 3, and reopen.

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
