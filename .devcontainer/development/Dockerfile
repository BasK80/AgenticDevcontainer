FROM node:20-bookworm

ARG USER_UID=1000
ARG USER_GID=1000

# Defensive: some compose implementations (e.g. Rancher Desktop) leak the
# service `environment` block into the build. We must clear:
#   - NODE_OPTIONS=-r global-agent/bootstrap → every node/npm invocation fails
#     with MODULE_NOT_FOUND until global-agent is installed below.
#   - HTTP(S)_PROXY=http://firewall:3128 → npm/curl try to reach the firewall
#     host, which doesn't exist at build time (only on the runtime compose
#     network), and fail with EAI_AGAIN.
# Compose re-injects all of these at container start, so runtime is unaffected.
ENV NODE_OPTIONS="" \
    HTTP_PROXY="" \
    HTTPS_PROXY="" \
    http_proxy="" \
    https_proxy="" \
    NO_PROXY="" \
    no_proxy="" \
    GLOBAL_AGENT_HTTP_PROXY=""

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg lsb-release \
      vim zsh tmux \
      iproute2 dnsutils \
      ripgrep fd-find fzf jq \
      build-essential \
      python3 python3-pip python3-venv pipx \
      less man-db \
    && ln -s $(which fdfind) /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Azure CLI — remove this block if you don't need Azure access (saves ~200 MB).
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# GitHub CLI.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Non-root user matching host UID/GID.
RUN if id -u node >/dev/null 2>&1; then \
        usermod -l devuser node && groupmod -n devuser node && \
        usermod -d /home/devuser -m devuser && usermod -s /bin/zsh devuser; \
    else \
        groupadd -g ${USER_GID} devuser && \
        useradd -u ${USER_UID} -g ${USER_GID} -m -s /bin/zsh devuser; \
    fi

RUN mkdir -p /commandhistory && chown devuser:devuser /commandhistory

# Pre-create mount points for named volumes so Docker initializes them with
# devuser ownership instead of root (volumes inherit perms from the image dir).
RUN mkdir -p \
        /home/devuser/.claude \
        /home/devuser/.claude-json \
        /home/devuser/.npm \
        /home/devuser/.cache/pip \
        /home/devuser/.cache/uv \
        /home/devuser/.cargo/registry \
        /workspace/node_modules \
    && chown -R devuser:devuser \
        /home/devuser/.claude \
        /home/devuser/.claude-json \
        /home/devuser/.npm \
        /home/devuser/.cache \
        /home/devuser/.cargo \
        /workspace/node_modules

# ── Egress proxy plumbing ─────────────────────────────────────────────────
# Runtime proxy env vars (HTTP_PROXY, HTTPS_PROXY, NO_PROXY, NODE_OPTIONS,
# GLOBAL_AGENT_HTTP_PROXY) are injected by compose's `environment:` block.
# We deliberately do NOT set them as image ENV: `firewall` is unreachable
# during `docker build`, so any proxy-aware tool (npm, curl) would fail.
# The git/npm proxy configs below bake the value into /etc/gitconfig and
# /root/.npmrc so it persists when env vars happen to be missing.

RUN git config --system http.proxy  http://firewall:3128 \
 && git config --system https.proxy http://firewall:3128

# Install global-agent system-wide BEFORE writing the npm proxy config:
# during `docker build`, the `firewall` host is unreachable, so npm must go
# direct. VS Code Server's bundled Node (which has its own module search
# path and does NOT see /home/devuser/.npm-global) can still resolve it
# from /usr/local/lib/node_modules via NODE_PATH set further down.
RUN npm install -g global-agent

# v4 dropped the root-level `bootstrap.js` shim that self-invoked on require,
# so the canonical `NODE_OPTIONS=-r global-agent/bootstrap` recipe no longer
# both resolves AND activates the proxy. Ship our own one-line shim that
# requires the v4 routine and calls it; NODE_OPTIONS points at this file.
RUN printf "require('global-agent/dist/routines/bootstrap').default();\n" \
      > /usr/local/lib/global-agent-bootstrap.js

RUN npm config set proxy http://firewall:3128 \
 && npm config set https-proxy http://firewall:3128

# Writable npm-global prefix — must be set before USER switch.
ENV NPM_CONFIG_PREFIX=/home/devuser/.npm-global
ENV PATH=/home/devuser/.npm-global/bin:$PATH
RUN mkdir -p /home/devuser/.npm-global && chown -R devuser:devuser /home/devuser/.npm-global

USER devuser
WORKDIR /workspace

# Claude Code goes into devuser's prefix so it can be updated without root.
RUN npm install -g @anthropic-ai/claude-code

# NODE_PATH points at the system-wide npm root so any Node binary — including
# VS Code Server's bundled node — can resolve `global-agent` when the shim
# preloads it. Set AFTER all build-time `npm`/`node` invocations so the
# preload file is guaranteed to exist when it's referenced.
ENV NODE_PATH=/usr/local/lib/node_modules \
    GLOBAL_AGENT_HTTP_PROXY=http://firewall:3128 \
    NODE_OPTIONS=-r\ /usr/local/lib/global-agent-bootstrap.js

COPY --chown=devuser:devuser .zshrc /home/devuser/.zshrc

CMD ["sleep", "infinity"]
