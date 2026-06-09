# ── History ──────────────────────────────────────────────────────────────────
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=50000
export SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_VERIFY

# ── Path ─────────────────────────────────────────────────────────────────────
export PATH=$HOME/.local/bin:$HOME/.dotnet/tools:$PATH

# ── Completion ───────────────────────────────────────────────────────────────
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'   # case-insensitive

# ── Key bindings ─────────────────────────────────────────────────────────────
bindkey -e                                    # emacs: Ctrl+A/E, Alt+F/B, etc.
bindkey '^[[A' history-search-backward        # Up   → history prefix search
bindkey '^[[B' history-search-forward         # Down → history prefix search
bindkey '^[[H' beginning-of-line              # Home
bindkey '^[[F' end-of-line                    # End
bindkey '^[[3~' delete-char                   # Delete

# ── Prompt (vcs_info for git branch + dirty/staged indicators) ───────────────
autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:*'     enable git
zstyle ':vcs_info:git:*' check-for-changes yes
zstyle ':vcs_info:git:*' unstagedstr  '✗'
zstyle ':vcs_info:git:*' stagedstr    '✓'
zstyle ':vcs_info:git:*' formats      ' (%F{green}%b%f%u%c)'
zstyle ':vcs_info:git:*' actionformats ' (%F{green}%b%f|%F{yellow}%a%f%u%c)'

setopt PROMPT_SUBST

# Prompt: user@host path (branch ✗/✓) ❯
# The ❯ turns red when the last command failed.
PROMPT='%F{cyan}%n%f@%F{blue}%m%f %F{yellow}%~%f${vcs_info_msg_0_} %(?.%F{green}.%F{red})❯%f '

# ── Aliases ───────────────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias g='git'
alias gs='git status -sb'
alias gl='git log --oneline --graph --decorate -20'

# ── Misc options ──────────────────────────────────────────────────────────────
setopt AUTO_CD           # type a directory name to cd into it
setopt CORRECT           # suggest corrections for typos
setopt NO_BEEP

# ── Provider switching (claude-switch.sh) ─────────────────────────────────────
[ -f /workspace/.devcontainer/development/claude-switch.sh ] && \
    source /workspace/.devcontainer/development/claude-switch.sh
