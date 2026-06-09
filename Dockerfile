# claude-isolated sandbox image (arm64 / aarch64 host).
#
# Node 22 base (bump to node:24-bookworm-slim if you want host parity). Bundles a
# filtering forward proxy (squid), Python, the GitHub CLI, and a Chromium for
# Playwright, then runs Claude Code as a non-root agent behind a default-deny
# egress firewall. See entrypoint.sh for how the runtime guardrails come up.
FROM node:22-bookworm-slim

# Pin Claude Code for reproducible builds (host runs 2.1.161).
ARG CLAUDE_CODE_VERSION=2.1.161

# Pin the Postgres major version baked in for project databases (opt-in at runtime).
ARG POSTGRES_VERSION=16

# Pin pnpm. A concrete version (not the `latest` tag) stops corepack from
# re-resolving it against the npm registry on every invocation — that network
# round-trip plus corepack's download prompt is what hangs an offline/non-allowlisted agent.
ARG PNPM_VERSION=11.5.1

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

# --- PostgreSQL (server + client), for opt-in per-project databases -----------
# Installed dormant: the image ships it but the entrypoint only starts a cluster
# when a project's .claude-isolated.json asks for one. PGDG repo because bookworm
# defaults to PG 15. The package auto-creates a root/postgres-owned cluster we
# never use, so drop it. Add the versioned bindir (initdb/pg_ctl live there, not
# on the default PATH) to the agent PATH via ENV below.
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        "postgresql-${POSTGRES_VERSION}" \
        "postgresql-client-${POSTGRES_VERSION}" \
    && pg_dropcluster --stop "${POSTGRES_VERSION}" main 2>/dev/null || true \
    && echo "export PATH=/usr/lib/postgresql/${POSTGRES_VERSION}/bin:\$PATH" \
         > /etc/profile.d/postgresql.sh \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm via corepack -------------------------------------------------------
# COREPACK_HOME holds the prepared package-manager cache. The default
# (~/.cache/node/corepack) lands in *root's* home at build time, which the
# non-root agent (uid 1000) cannot read — so the agent's first `pnpm` would miss
# the cache and try to re-download, blocking on corepack's interactive prompt.
# Put the cache in a world-readable shared path instead, and disable the prompt
# so a cache miss can never silently hang. Both ENVs persist into the runtime,
# so the agent reads the same prepared cache and needs no network for pnpm.
ENV COREPACK_HOME=/opt/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && chmod -R a+rX /opt/corepack

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

# --- Proxy config ------------------------------------------------------------
# The egress allowlist is NOT baked in: it is the host-side config's single
# source of truth, written to /etc/squid/allowlist.txt at startup by the
# entrypoint (from SANDBOX_ALLOWLIST) before squid boots. squid.conf reads that
# path. Adding a host is a config edit + re-run — no rebuild.
COPY squid.conf    /etc/squid/squid.conf

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
# proxy hop itself and local dev servers aren't re-proxied.
#
# We deliberately DON'T set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC (or its
# DISABLE_TELEMETRY component): that umbrella var also disables feature-flag
# evaluation (GrowthBook/Statsig), and Remote Control is gated behind the
# tengu_ccr_bridge feature flag. In current Claude Code the feature-flag service
# shares a kill switch with telemetry, so keeping Remote Control working means
# letting that traffic through. It only targets .anthropic.com, which the
# allowlist already permits. Only the autoupdater is suppressed — it's pointless
# in a version-pinned image and an in-container update wouldn't persist anyway.
ENV HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    http_proxy=http://127.0.0.1:3128 \
    https_proxy=http://127.0.0.1:3128 \
    NO_PROXY=localhost,127.0.0.1,::1 \
    no_proxy=localhost,127.0.0.1,::1 \
    DISABLE_AUTOUPDATER=1 \
    PATH=/usr/lib/postgresql/16/bin:$PATH

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
