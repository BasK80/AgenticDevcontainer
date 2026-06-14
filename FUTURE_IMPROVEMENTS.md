# Future (possible) improvements
This document is a braindump of ideas for improvements that I get when using this container or get as feedback from other users. I've roughly sorted the ideas into maintainability, usability and security improvements.

## Maintainability
### ~~Clean up the post-create & post-install logic for the development container~~ ✅ Done
~~The current post-create.sh, post-install.sh and devcontainer.json have overlaping logic that was organically created to fix certain issues during development of this container. This needs some TLC to make this much more consistent and streamlined.~~

Each lifecycle hook now has a single, clearly defined responsibility:
- `post-create.sh` — one-time setup only: provider selection, `settings.json`, `allowedPaths`, `.zshrc` registration.
- `post-start.sh` — every-start setup: `~/.claude.json` symlink and Azure CLI browser-login flag (for Foundry).
- `devcontainer.json` `postStartCommand` — delegates entirely to `post-start.sh` with no inline logic.

Also fixed a bug in the `fw` script: line 9 was missing its `#` comment prefix (running `docker exec` as live code before `set -euo pipefail`), and the usage message had broken shell quoting.

### ~~Remove the logic of the 'fw' tool~~ ✅ Done
~~Remove the fw tool, it's logic is already better provided by the web ui in the control container. Make the logic provided by the fw tool more easily available on the firewall container itself and update the description in the README on how to work without the control container to use this new tooling in the firewall container.~~

`tools/fw` has been removed. A native `fw` script now lives directly on the firewall container (`/usr/local/bin/fw`) and supports `allow`, `deny`, `list`, `blocks`, and `log`. README and USAGE both document `docker exec "$FW" fw <command>` as the management interface.

### Move to Node 24 LTS ✅ Done
The development image now runs on **`node:24-bookworm`** — Step 6.1 bumped it from `node:22-bookworm` (Step 3.3 had moved it 20→22 for Copilot CLI). The toolchain now sits on the current Node 24 LTS rather than the aging 22 line.

Because every AI tool in the image runs on this Node (Claude Code, opencode, Copilot CLI), the bump was validated with a one-off regression test run from inside the container after the rebuild: it asserted Node ≥ 24, that every tool reported a version, that firewall egress still worked (allowlisted host reachable, non-allowlisted blocked with 403), that the block feed was reachable, and — with provider creds present — that `claude`/`opencode` completed a real round-trip through the proxy. Note: egress was checked at the proxy layer with `curl`, not via a raw `node fetch`; the earlier proxy fix removed the `global-agent` `NODE_OPTIONS` shim, so Node's native `fetch` no longer self-routes through Squid — the tools use proxy-aware HTTP libraries instead. All checks passed, so the temporary verification script was removed. The detailed step lives in *Step 6.1* in `FUTURE_IMPROVEMENTS_IMPLEMENTATION_PLAN.md`.

**Scheduling:** done **after all other improvements except the pentest** — it touches the base image, so the automated pentest (the final step) should run against the Node 24 image.

## Usability
### ~~More fine-grained .devcontainer mount~~ ✅ Done
~~The .devcontainer directory is fully mounted read-only, so you cannot make any changes to the setup from within the agentic development container, that would become active after a rebuild. This is an important security feature, but it is a bit too broad, since most of the files in .devcontainer/development pose no security risk at all if they are edited by a user or agent and that would make life a lot easier.~~

The blanket `../.devcontainer:/workspace/.devcontainer:ro` mount is replaced with granular per-path mounts. `development/` is writable, allowing in-container edits to `.zshrc`, `llm-switch.sh`, and similar user-experience files. Security-perimeter files (`Dockerfile`, `post-create.sh`, `post-start.sh`, `firewall/`, `control/`, `docker-compose.yml`, `devcontainer.json`, `.env`, `initialize.sh`) remain individually read-only.

### ~~Support for copilot cli~~ ✅ Done
~~The current version of this solution is fully focussed on claude code, but I would like to extend this with support to copilot cli out of the box as well. The scripts that switch between backend llm providers should support set up the environment for both claude and copilot cli where possible and if a provider can only be used with either claude or copilot, then the switch script should state this clearly.~~

The GA agentic **GitHub Copilot CLI** (npm `@github/copilot`, command `copilot`) is now installed in the development image as a third agentic coding tool alongside `claude` and `opencode`, authenticated with your GitHub Copilot subscription via browser device login (`copilot` → `/login`) — no token to manage. It turned out Copilot CLI has its **own** auth and is therefore independent of the provider-switch scripts: `llm-switch.sh` routes `claude`/`opencode` over Anthropic-compatible endpoints and does not apply to `copilot`, which is stated in that script and in USAGE/README. The required base-image bump to `node:22-bookworm` landed here too. See the "GitHub Copilot CLI" section in `README.md` and Step 3.3 in `FUTURE_IMPROVEMENTS_IMPLEMENTATION_PLAN.md`.

### ~~Support for opencode~~ ✅ Done
~~Same story as for the copilot cli, but with opencode.~~

`opencode` is installed in the development image and wired into `llm-switch.sh` alongside Claude Code: switching providers with `use-anthropic-key`, `use-foundry`, or `use-anthropic` configures **both** tools at once. See Step 3.1 in `FUTURE_IMPROVEMENTS_IMPLEMENTATION_PLAN.md`.

### ~~Support for GitHub copilot SDK~~ ✅ Done
~~The current setup works with an anthropic account, LLM's in Azure foundry or an Anthropic API key to either Anthropic itself or a third-party LLM gateway. In many organisations the preferred way to use LLM's is through GitHub copilot, so having out-of-the-box support for the copilot SDK would be a big improvement.~~

**Update (2026-06-13):** Researched the Claude Code angle. The clean path is `opencode`, which supports Copilot natively via a `GITHUB_TOKEN`. Routing **Claude Code** through a Copilot subscription is *not* viable out of the box: Claude Code hardcodes `x-api-key` auth (no bearer-token gateway mode — the upstream feature request was closed as "not planned"), and `api.githubcopilot.com` requires Copilot-editor client headers. It only works through a reverse-engineered local proxy that impersonates the Copilot client, which loses extended thinking and is a ToS gray area — so the Claude Code sub-path is dropped. **Implemented for opencode via GitHub browser device login** (run `apply-step-3.2.sh` on the host to allowlist `.githubcopilot.com` + `models.dev`, then `/connect` → GitHub Copilot inside opencode and authorise in the browser — no token to manage). See the "GitHub Copilot (opencode)" section in `README.md` and Step 3.2 in `FUTURE_IMPROVEMENTS_IMPLEMENTATION_PLAN.md` for details.

### Skill/tool guide
I do not want to preload this image with skills or tools, since they are too volatile and would add a lot of maintenance overhead. It would be helpful however to add a guide on where to find good (Info Support) skills and tools and how to use them in the development container.

### ~~Better 'boot' experience~~ ✅ Done
~~When you currently open the container you have to manually open a terminal after the container has fully booted. This is counter-intuitive and should happen automatically.~~

A `.vscode/tasks.json` task with `runOn: "folderOpen"` now opens a focused `zsh` terminal panel automatically when the workspace folder opens. VS Code asks to "Allow Automatic Tasks" once; after that the terminal appears on every attach. No rebuild needed — the file lives in `/workspace`. See *Step 4.1* in `FUTURE_IMPROVEMENTS_IMPLEMENTATION_PLAN.md`.

### Add useful default linux tools
Right now I know I'm missing the 'ping' tool, but there are probably more tools that should be part of the base image. Since you have no root permissions within the development container, you can't simply install them as needed. Maybe also add a short section to the README on how to add new tools like this. 

### Firewall-aware AI tools
When an AI tool tries to reach a domain that is blocked by the firewall, it currently receives a generic network error. The tool has no way to distinguish "this domain doesn't exist" from "this domain is blocked by a firewall". As a result, the tool may retry, suggest workarounds, or report a confusing error to the user instead of simply saying "this domain is not on the allowlist — add it via the control UI or the firewall container". Ideally the tools would be made aware that they are running behind a firewall, so they can give the user a clear and actionable message. Possible approaches: set a system prompt addition that explains the network topology and how to request allowlist changes, configure a custom Squid error page that includes allowlist instructions (visible when the tool follows a redirect or renders HTML), or provide a small wrapper/hook that intercepts CONNECT-denied responses and prepends a human-readable explanation before surfacing the error to the model.

## Security
### Better control over the firewall allowlist.default
The current allowlist is too large. I would like to have be able to enable certain features in the devcontainer that describe how it will be used, for example if we need npm packages, or access to Azure. This should correspond to the corresponding domains being added to the default allowlist. Note: this feature should be further refined when being implemented, since the devcontainer.json might not be the best place for this. I can imagine that it would be extremely nice to be able to configure this from the control webui, either permanently or temporarily (like with individual domains), but in that case we would need a corresponding fallback in the firewall container itself.

### Run an automated test pentest from within the container
The goal of this solution is to have a secure environment where a rogue agent cannot harm anything outside of the container. I would like to test this by having an agent team try to find ways to bypass this security from within the container.
