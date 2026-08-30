# syntax=docker/dockerfile:1
#
# herdr-box — a persistent dev box for coding agents, reachable over SSH,
# built to run as a StatefulSet pod in the k3s cluster.
#
# Everything that is *software* lives in the image (/usr, /opt).
# Everything that is *state* lives in /home/dev (PVC) and /etc/ssh/hostkeys
# (PVC subPath, so the SSH host identity survives pod rescheduling).

FROM debian:13-slim

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Pinned versions — Renovate bumps these (see renovate.json)
ARG NODE_VERSION=24.13.0
ARG HERDR_VERSION=0.8.2
ARG CLAUDE_CODE_VERSION=2.1.251
ARG CODEX_VERSION=0.151.0
ARG OPENCODE_VERSION=1.18.25

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg openssh-server openssh-client sudo tini \
        locales tzdata git git-lfs \
        vim less nano bash-completion man-db \
        build-essential pkg-config \
        ripgrep fd-find fzf jq tree htop procps psmisc lsof \
        python3 python3-venv \
        unzip zip xz-utils rsync netcat-openbsd iputils-ping dnsutils \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# *//' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# GitHub CLI (official apt repository)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# kubectl (agents talk to the cluster via GitOps + kubectl, no docker-in-docker)
RUN KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
         -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# ---------------------------------------------------------------------------
# Runtimes: Node.js and uv, into /usr/local so they survive a wiped home
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' \
    && node --version && npm --version

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && uv --version

# ---------------------------------------------------------------------------
# herdr — pinned release binary, no `curl | sh`
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" \
      -o /usr/local/bin/herdr \
    && chmod +x /usr/local/bin/herdr \
    && herdr --version

# ---------------------------------------------------------------------------
# Coding agents
# ---------------------------------------------------------------------------
RUN npm install -g --no-fund --no-audit \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force \
    && claude --version && codex --version && opencode --version

# ---------------------------------------------------------------------------
# The user you log in as
# ---------------------------------------------------------------------------
RUN groupadd -g "${USER_GID}" "${USERNAME}" \
    && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-herdr-box \
    && chmod 0440 /etc/sudoers.d/90-herdr-box \
    && mkdir -p /run/sshd

# ---------------------------------------------------------------------------
# sshd config, entrypoint, env plumbing
# ---------------------------------------------------------------------------
COPY image/sshd_config /etc/ssh/sshd_config
COPY image/entrypoint.sh /usr/local/bin/herdr-box-entrypoint

# The entrypoint dumps selected container env (e.g. CLAUDE_CODE_OAUTH_TOKEN)
# into /run/herdr-box/env.sh; sshd sessions don't inherit container env, so
# both login shells (ssh) and interactive shells (herdr panes) source it.
RUN chmod +x /usr/local/bin/herdr-box-entrypoint \
    && printf '[ -r /run/herdr-box/env.sh ] && . /run/herdr-box/env.sh\n' \
         > /etc/profile.d/90-herdr-box.sh \
    && printf '\n# herdr-box\n[ -r /run/herdr-box/env.sh ] && . /run/herdr-box/env.sh\n' \
         >> /etc/bash.bashrc

EXPOSE 22

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/herdr-box-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
