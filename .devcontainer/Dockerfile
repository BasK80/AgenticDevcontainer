FROM node:20-bookworm

ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg lsb-release \
      vim zsh tmux sudo \
      iptables ipset iproute2 dnsutils \
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

# Sudoers: devuser may run ONLY the firewall script as root, no password.
RUN echo 'devuser ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh' \
      > /etc/sudoers.d/devuser-firewall \
    && chmod 0440 /etc/sudoers.d/devuser-firewall

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

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh && chown root:root /usr/local/bin/init-firewall.sh

# Writable npm-global prefix — must be set before USER switch.
ENV NPM_CONFIG_PREFIX=/home/devuser/.npm-global
ENV PATH=/home/devuser/.npm-global/bin:$PATH
RUN mkdir -p /home/devuser/.npm-global && chown -R devuser:devuser /home/devuser/.npm-global

USER devuser
WORKDIR /workspace

RUN npm install -g @anthropic-ai/claude-code

RUN echo 'export HISTFILE=/commandhistory/.zsh_history' >> ~/.zshrc && \
    echo 'export HISTSIZE=10000 SAVEHIST=10000' >> ~/.zshrc && \
    echo 'setopt SHARE_HISTORY' >> ~/.zshrc && \
    echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc

CMD ["sleep", "infinity"]
