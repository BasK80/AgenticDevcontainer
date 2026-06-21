# Spin-off guide: adding agent tooling to an existing repo

This guide walks through dropping this devcontainer setup into a codebase you already own, while keeping a live upstream link so you can pull in future improvements (new skills, firewall fixes, provider updates) with a standard git merge.

The example throughout uses a fictional legacy codebase called `acme-corp/legacy-moderniser`. Substitute your own org and repo name everywhere you see it.

---

## Strategy

Your repo forks this project on GitHub and adds it as a second git remote (`upstream`). Your customizations live exclusively in the designated extension points (skills, `post-create.sh`, firewall feature lists) — not in the core infrastructure files. This keeps merge conflicts to near-zero when you pull upstream updates.

---

## Step 1: Fork on GitHub

1. Go to `https://github.com/BasKloetIS/AgenticDevcontainer` and click **Fork**.
2. Name the fork `legacy-moderniser` under your org: `acme-corp/legacy-moderniser`.

> You are forking the *template* here, not your actual project code. In step 3 you will move this fork's `.devcontainer/` content into your real repo.

---

## Step 2: Clone your real project

```bash
git clone https://github.com/acme-corp/legacy-moderniser.git
cd legacy-moderniser
```

If your project repo already exists locally, just `cd` into it.

---

## Step 3: Add the upstream remote

Inside your project repo, register the original template as a second remote:

```bash
git remote add upstream https://github.com/BasKloetIS/AgenticDevcontainer.git
git fetch upstream
```

You now have two remotes:
- `origin` → your project (`acme-corp/legacy-moderniser`)
- `upstream` → the template (`BasKloetIS/AgenticDevcontainer`)

---

## Step 4: Copy the devcontainer files into your repo

Merge the template's `main` branch into yours, keeping only the infrastructure files:

```bash
git merge upstream/main --allow-unrelated-histories -m "chore: add agentic devcontainer infrastructure"
```

If you already have files that conflict (e.g. a `README.md`), Git will flag them. Keep your versions:

```bash
# Keep your existing README, discard the template's
git checkout HEAD -- README.md
git add README.md
git commit --amend --no-edit
```

After the merge, your repo contains:

```
your-project/
├── .devcontainer/       ← infrastructure (track upstream)
├── .vscode/tasks.json   ← infrastructure (track upstream)
├── .claude/skills/      ← yours to extend
├── CLAUDE.md            ← yours to extend
├── AGENTS.md            ← yours to extend
├── tools/               ← infrastructure (track upstream)
├── .gitattributes       ← keep as-is
└── ... your existing project files
```

The merge also brings in template-specific files you don't need. Remove them:

```bash
# Remove template documentation that belongs to the upstream project, not yours
git rm USAGE.md presentation.html
git rm docs/comparison.md   # template-specific comparison doc; keep the rest

git commit -m "chore: remove template-specific docs"
```

Keep `CLAUDE.md` and `AGENTS.md` — you will extend them in step 5.

---

## Step 5: Make your customizations

All your changes go into the extension points listed below. **Do not edit the core infrastructure files directly** — that is what keeps upstream merges clean.

### 5a. Add your project's dependencies — `post-create.sh`

`post-create.sh` runs once on first container creation. Open it **on the host** (it is read-only inside the container — see [Read-only files](#read-only-files-and-what-that-means-for-you)) and uncomment the template that matches your stack:

```bash
# Node
npm ci

# Python (pip)
pip install -r requirements.txt

# Python (uv)
uv sync
```

Add as many install commands as your project needs.

> **Why host-only?** `post-create.sh` is bind-mounted `:ro` into the container. This is a security measure — it prevents an in-container agent from modifying the setup script that runs with elevated trust on first boot. Always edit it from the host, then rebuild.

### 5b. Open the firewall for your project's domains

Add a new feature-set file for your project's required domains. Create it **on the host**:

```bash
# From the host, inside your project directory:
cat > .devcontainer/firewall/features/legacy-moderniser.list << 'EOF'
# Domains required by acme-corp/legacy-moderniser
maven.apache.org
repo1.maven.org
jfrog.acme-corp.internal
EOF
```

Then rebuild the firewall image and enable the feature-set:

```bash
docker compose -f .devcontainer/docker-compose.yml build firewall
docker compose -f .devcontainer/docker-compose.yml up -d

FW="claude-$(basename "$PWD")-firewall"
docker exec "$FW" fw feature on legacy-moderniser
```

Alternatively, once the container is running you can enable the feature-set from the **web dashboard** at <http://127.0.0.1:8088> — find your new feature-set in the feature toggles list and switch it on. The CLI and the dashboard write to the same policy volume and are always in sync.

> **Why host-only?** The entire `firewall/` directory is bind-mounted `:ro`. This is intentional — an agent operating on untrusted input cannot add itself a new network path. Firewall changes must come from a human on the host.

### 5c. Add your own skills — `.claude/skills/`

Drop a directory with a `SKILL.md` file into `.claude/skills/`. This directory is writable from inside the container, so you can create skills from either the host or inside the container.

```
.claude/skills/
└── java-refactor/
    └── SKILL.md
```

See the `write-a-skill` bundled skill for the correct `SKILL.md` structure (trigger it by asking the agent to "write a new skill").

### 5d. Update the agent guides — `CLAUDE.md` / `AGENTS.md`

These files are writable. Add a project-specific section at the top so agents understand your codebase:

```markdown
## Project context

This is a Java 8 → Java 21 modernisation project. The main module is `legacy-api/`.
Build with `mvn package -DskipTests`. The test suite takes ~12 minutes; always skip
during refactoring passes and run once at the end.
```

The firewall-awareness note at the bottom of both files should be left intact — agents need it to understand the network topology.

---

## Read-only files and what that means for you

Some files you will want to customize are **read-only inside the running container**. This is a security property of the setup, not an accident. The files are bind-mounted `:ro` from the host so that an agent running inside the container cannot modify its own security perimeter or setup hooks.

| File | Read-only in container? | How to edit |
|---|---|---|
| `.devcontainer/development/post-create.sh` | **Yes** | Edit on the host, then rebuild |
| `.devcontainer/development/post-start.sh` | **Yes** | Edit on the host, then rebuild |
| `.devcontainer/firewall/features/*.list` | **Yes** (whole `firewall/` dir) | Edit on the host, then rebuild firewall image |
| `.devcontainer/development/.zshrc` | No | Edit freely from inside the container or the host |
| `.claude/skills/` | No | Edit freely from inside the container or the host |
| `CLAUDE.md` / `AGENTS.md` | No | Edit freely from inside the container or the host |

**The rebuild step.** After editing a read-only file on the host:

```bash
# Rebuild the development container (for post-create.sh / post-start.sh changes):
# VS Code → Command Palette → Dev Containers: Rebuild Container
# Or from the host:
docker compose -f .devcontainer/docker-compose.yml build development
docker compose -f .devcontainer/docker-compose.yml up -d

# Rebuild the firewall image (for firewall/features/ changes):
docker compose -f .devcontainer/docker-compose.yml build firewall
docker compose -f .devcontainer/docker-compose.yml up -d
```

---

## File ownership: what to touch vs. what to leave alone

| Track upstream — do not edit directly | Yours to customize |
|---|---|
| `.devcontainer/firewall/` (core scripts, squid.conf) | `.devcontainer/firewall/features/` (add your own `.list` files) |
| `.devcontainer/control/` *(user-friendly web UI for the firewall, host-side only — project-specific changes are rarely needed)* | `.devcontainer/development/post-create.sh` *(host-only edits)* |
| `.devcontainer/docker-compose.yml` | `.devcontainer/development/post-start.sh` *(host-only edits)* |
| `.devcontainer/devcontainer.json` | `.devcontainer/development/.zshrc` |
| `.devcontainer/development/Dockerfile` | `.claude/skills/` |
| `.devcontainer/development/llm-switch.sh` | `CLAUDE.md` / `AGENTS.md` |
| `.devcontainer/development/post-create.sh` | `.claude/settings.local.json` |
| `.vscode/tasks.json` | Your project source code |
| `tools/` | `README.md` |

The key principle: if a file is read-only inside the container, treat it as upstream-owned. Your customizations live exclusively in the writable extension points.

---

## Pulling upstream updates

When this template ships improvements you want:

```bash
git fetch upstream
git merge upstream/main
```

Because your changes are in the extension points (skills, `post-create.sh`, feature lists, agent guides) and not in the core files, most merges will be conflict-free. If there is a conflict in a core file you have intentionally modified, use `git diff upstream/main -- <file>` to review upstream's changes and fold them in manually.

After merging, rebuild if any container files changed:

```bash
docker compose -f .devcontainer/docker-compose.yml build
docker compose -f .devcontainer/docker-compose.yml up -d
```

---

## Committing and pushing

```bash
git add .devcontainer .claude CLAUDE.md AGENTS.md .vscode .gitattributes
git commit -m "chore: add agentic devcontainer infrastructure"
git push origin main
```

Your team members get the full agent setup on their next `git pull` + container rebuild.

> **`.gitignore` check.** Ensure your `.gitignore` excludes `**/.claude/settings.local.json` and `.devcontainer/.env` — these are personal and contain credentials. The template's `.gitignore` already covers this; verify it merged correctly.
