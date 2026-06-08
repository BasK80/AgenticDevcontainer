FROM node:20-bookworm

ARG USER_UID=1000
ARG USER_GID=1000

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
# Subject has no direct route to the internet; the only path out is the
# Squid proxy at firewall:3128. Tools that don't honour these env vars fail
# closed (no route), which is the intended behaviour.
ENV HTTP_PROXY=http://firewall:3128 \
    HTTPS_PROXY=http://firewall:3128 \
    http_proxy=http://firewall:3128 \
    https_proxy=http://firewall:3128 \
    NO_PROXY=localhost,127.0.0.1,firewall \
    no_proxy=localhost,127.0.0.1,firewall \
    GLOBAL_AGENT_HTTP_PROXY=http://firewall:3128 \
    NODE_OPTIONS=-r\ global-agent/bootstrap

RUN git config --system http.proxy  http://firewall:3128 \
 && git config --system https.proxy http://firewall:3128

RUN npm config set proxy http://firewall:3128 \
 && npm config set https-proxy http://firewall:3128

# Writable npm-global prefix — must be set before USER switch.
ENV NPM_CONFIG_PREFIX=/home/devuser/.npm-global
ENV PATH=/home/devuser/.npm-global/bin:$PATH
RUN mkdir -p /home/devuser/.npm-global && chown -R devuser:devuser /home/devuser/.npm-global

USER devuser
WORKDIR /workspace

# global-agent makes Node's native http/https/fetch honour HTTP(S)_PROXY,
# which Node itself ignores. Required because Claude Code, MCP servers, and
# most VS Code extensions are Node processes on internal-only networking.
RUN npm install -g @anthropic-ai/claude-code global-agent

RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
    echo 'export HISTSIZE=10000 SAVEHIST=10000' >> ~/.zshrc && \
    echo 'setopt SHARE_HISTORY' >> ~/.zshrc && \
    echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc

CMD ["sleep", "infinity"]
