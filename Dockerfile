# claude-isolated sandbox image (arm64 / aarch64 host).
#
# Node 22 base (bump to node:24-bookworm-slim if you want host parity). Bundles a
# filtering forward proxy (squid), Python, the GitHub CLI, and a Chromium for
# Playwright, then runs Claude Code as a non-root agent behind a default-deny
# egress firewall. See entrypoint.sh for how the runtime guardrails come up.
FROM node:22-bookworm-slim

# Pin Claude Code for reproducible builds (host runs 2.1.161).
ARG CLAUDE_CODE_VERSION=2.1.161

ENV DEBIAN_FRONTEND=noninteractive

# --- OS packages -------------------------------------------------------------
# squid               : the domain-filtering proxy (the one path out)
# iptables            : default-deny egress firewall, set by root at startup
# python3/pip/venv    : arbitrary Python in the workspace
# git/curl/jq/ca-certs: everyday agent tooling
# gh                  : GitHub CLI (PRs, auth) — installed from its own apt repo
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && install -m 0755 -d /usr/share/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        squid \
        iptables \
        python3 \
        python3-pip \
        python3-venv \
        git \
        jq \
        gh \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm via corepack -------------------------------------------------------
RUN corepack enable && corepack prepare pnpm@latest --activate

# --- Claude Code -------------------------------------------------------------
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# --- Playwright + Chromium ---------------------------------------------------
# Install the browser into a world-readable shared path (not /root/.cache) so the
# non-root agent finds it. install-deps pulls the chromium OS libraries via apt.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright \
    && playwright install-deps chromium \
    && playwright install chromium \
    && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH" \
    && rm -rf /var/lib/apt/lists/*

# --- Non-root agent at uid/gid 1000 -----------------------------------------
# The base image ships a 'node' user at uid 1000; remove it and claim 1000 for
# 'agent' so bind-mounted files (owned by host uid 1000 'ubuntu') line up, and
# so --dangerously-skip-permissions is accepted (the CLI rejects it as root).
RUN userdel -r node 2>/dev/null || true \
    && groupadd -g 1000 agent \
    && useradd -m -u 1000 -g 1000 -s /bin/bash agent

# --- Proxy config + egress allowlist ----------------------------------------
COPY squid.conf    /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt

# --- Entry + git push guard --------------------------------------------------
COPY entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY git-guard/pre-push   /etc/claude-isolated/git-hooks/pre-push
# 0755, not `chmod +x`: the entrypoint re-execs itself as the non-root agent, and
# a script run via its shebang must be READABLE by whoever runs it (execute-only
# is enough for binaries, not scripts). `chmod +x` on a 0600 file leaves 0711 (no
# read bit for 'other'), which makes phase 2 fail with "Permission denied".
RUN chmod 0755 /usr/local/bin/entrypoint.sh /etc/claude-isolated/git-hooks/pre-push

# --- Runtime env -------------------------------------------------------------
# Force all agent HTTP(S) through the in-container proxy; exempt loopback so the
# proxy hop itself and local dev servers aren't re-proxied. Kill telemetry and
# the autoupdater so the allowlist can stay tight.
ENV HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    http_proxy=http://127.0.0.1:3128 \
    https_proxy=http://127.0.0.1:3128 \
    NO_PROXY=localhost,127.0.0.1,::1 \
    no_proxy=localhost,127.0.0.1,::1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
