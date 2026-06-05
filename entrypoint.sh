#!/usr/bin/env bash
# Container entrypoint for the claude-isolated sandbox. Two phases:
#
#   1. root  — start the filtering proxy and program the egress firewall, then
#              drop to the unprivileged 'agent' user (uid 1000).
#   2. agent — configure git/gh, install the push guard, and exec Claude Code
#              with --dangerously-skip-permissions. The sandbox is the guard.
set -euo pipefail

PROXY_PORT=3128

# ---------------------------------------------------------------------------
# Phase 1: root. Bring up egress controls, then re-exec ourselves as 'agent'.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    proxy_uid="$(id -u proxy)"

    echo "[entrypoint] starting filtering proxy (squid) on 127.0.0.1:${PROXY_PORT}"
    # squid daemonizes; its worker runs as the 'proxy' user, the only uid the
    # firewall below lets reach the network.
    squid -f /etc/squid/squid.conf

    echo "[entrypoint] waiting for proxy to accept connections"
    ready=0
    for _ in $(seq 1 100); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${PROXY_PORT}") 2>/dev/null; then
            # The probe opens fd 3 in a SUBSHELL, so it's already closed in this
            # shell — nothing to clean up here. (A bare `exec 3>&- 2>/dev/null`
            # would be an exec-with-no-command and permanently redirect THIS
            # shell's stderr to /dev/null, silently swallowing every later
            # message — including phase 2's egress-self-test FATALs and the
            # agent's own stderr, since this fd state survives the runuser exec.)
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "[entrypoint] FATAL: proxy did not come up — refusing to start (fail closed)" >&2
        exit 1
    fi

    echo "[entrypoint] applying default-deny egress firewall (proxy-uid=${proxy_uid})"
    # Flush, then build an allow-list of OUTPUT rules and finally flip the
    # default policy to DROP. The agent (uid 1000) matches none of the ACCEPTs,
    # so its only reachable destination is loopback (the proxy).
    iptables -F
    iptables -X 2>/dev/null || true

    # Loopback: the agent -> proxy hop, and Docker's embedded DNS at 127.0.0.11.
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    # Return traffic for connections we already permitted.
    iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # ONLY the proxy uid may reach the network: DNS (to resolve allowlisted
    # hosts) and HTTP/HTTPS (to forward allowed requests). Nothing else.
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p udp --dport 53  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 53  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 80  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 443 -j ACCEPT

    # Inbound dev-server ports (opt-in, set by the wrapper's CLAUDE_ISOLATED_PORTS).
    # Docker DNATs the host's Tailscale port to this container; the packet arrives
    # here as a NEW inbound connection, so without an explicit ACCEPT the
    # default-DROP INPUT policy below would silently swallow it.
    for dev_port in ${SANDBOX_PORTS:-}; do
        case "$dev_port" in ''|*[!0-9]*) continue ;; esac
        iptables -A INPUT -p tcp --dport "$dev_port" -j ACCEPT
        echo "[entrypoint] allowing inbound dev-server port ${dev_port}/tcp"
    done

    # Default-deny everything else, inbound and out.
    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  DROP
    echo "[entrypoint] firewall active — agent has no path out except the proxy"

    # --- Make host-absolute config paths resolve inside the container ----------
    # Your real ~/.claude lives at $HOST_CLAUDE_DIR on the host (e.g. /data/.claude),
    # and config copied from it bakes that absolute path in: settings.json hook
    # commands ("python3 /data/.claude/hooks/x.py") and the plugin marketplace
    # manifests (installLocation). Inside the container ~/.claude is
    # /home/agent/.claude, so those paths would dangle. Symlink the host path to
    # the agent's real config dir so every baked-in reference resolves — this also
    # covers the plugin manifests, which live under the read-only /seed symlink and
    # so can't be rewritten in place. Done as root (the agent can't mkdir at /);
    # the target is assembled in phase 2, and a not-yet-existing target is fine.
    if [ -n "${HOST_CLAUDE_DIR:-}" ] && [ "$HOST_CLAUDE_DIR" != /home/agent/.claude ]; then
        mkdir -p "$(dirname "$HOST_CLAUDE_DIR")"
        ln -sfn /home/agent/.claude "$HOST_CLAUDE_DIR"
        echo "[entrypoint] linked ${HOST_CLAUDE_DIR} -> /home/agent/.claude (host config paths resolve)"
    fi

    # Drop privileges to the agent user and re-run this script as phase 2.
    # NET_ADMIN and root are left behind here; the agent never holds them.
    exec runuser -u agent -- "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Phase 2: agent (uid 1000, no NET_ADMIN). Configure tooling and run Claude.
# ---------------------------------------------------------------------------

# --- Verify the egress posture before handing control to the agent ------------
# Phase 1 only confirmed squid is *up*; it never confirmed the firewall actually
# *contains* the agent. Probe the real principal (uid 1000) now, same fail-closed
# stance as the proxy-startup wait. Two HARD checks (a breach launches nothing)
# and one SOFT check (a broken allowlist is a loud functional error, not an
# escape, and surfaces immediately as a Claude failure):
#
#   1. HARD — a connection that BYPASSES the proxy must not reach the network.
#      Uses a literal IP over plain HTTP so it tests the iptables OUTPUT drop and
#      not DNS or TLS: a DROP just times out (curl fails), while an open firewall
#      cleanly connects to 1.1.1.1:80 and curl exits 0. (HTTPS would muddy this —
#      a failed cert check also exits non-zero, masking a real breach.)
#   2. HARD — a request THROUGH the proxy to a non-allowlisted host must be denied
#      by squid (403), proving deny-all is in force, not merely that squid is up.
#      squid rejects on the dstdomain ACL before any DNS, so this works offline.
#   3. SOFT — a request through the proxy to an allowlisted host should succeed;
#      failure usually means the network is down or the allowlist is too tight, so
#      warn rather than abort.
echo "[entrypoint] verifying egress posture (agent uid=$(id -u))"

if curl --noproxy '*' --silent --connect-timeout 5 --output /dev/null \
        http://1.1.1.1 2>/dev/null; then
    echo "[entrypoint] FATAL: agent reached the network directly, bypassing the proxy (firewall breach) — refusing to start" >&2
    exit 1
fi

if curl --silent --connect-timeout 5 --output /dev/null \
        https://example.com 2>/dev/null; then
    echo "[entrypoint] FATAL: proxy forwarded a non-allowlisted host (squid is not denying) — refusing to start" >&2
    exit 1
fi

if curl --silent --connect-timeout 5 --max-time 10 --output /dev/null \
        https://api.github.com/zen 2>/dev/null; then
    echo "[entrypoint] egress posture OK — direct blocked, proxy denies non-allowlisted, allowlist reachable"
else
    echo "[entrypoint] WARNING: an allowlisted host was unreachable through the proxy — network down or allowlist too tight?" >&2
fi

# --- Assemble ~/.claude from a read-only seed + a writable state dir ----------
# Isolation model: your real host config is mounted READ-ONLY at /seed and is
# only ever copied FROM — the agent can never write back to it, so it cannot
# plant hooks, settings, plugins, or a malicious .claude.json that would later
# run in your normal host Claude sessions. The mutable state worth keeping
# (conversations, project memory, history, the sandbox's own .claude.json) lives
# in /state, a dedicated host dir SEPARATE from your real ~/.claude. Everything
# else the box does is thrown away when the container exits.
CLAUDE_HOME=/home/agent/.claude
if [ -d /seed ]; then
    mkdir -p "$CLAUDE_HOME"
    # Copy small config items out of the seed, skipping bulk/state paths: those
    # are either huge (projects/), mounted read-only (plugins/), or persisted via
    # /state. --preserve=mode keeps permission bits (e.g. .credentials.json 600)
    # without attempting chown, which would fail as a non-root user.
    for item in /seed/* /seed/.[!.]*; do
        [ -e "$item" ] || continue
        case "$(basename "$item")" in
            projects|plugins|todos|history.jsonl|.claude.json|file-history|backups|cache|paste-cache|shell-snapshots)
                continue ;;
        esac
        cp -r --preserve=mode "$item" "$CLAUDE_HOME/" 2>/dev/null || true
    done
    # Plugins: read-only, straight from the host seed (no copy, cannot be altered).
    ln -sfn /seed/plugins "$CLAUDE_HOME/plugins"
fi

# Persistent state -> /state (a host dir separate from your real ~/.claude).
# Directory symlinks are safe for these (files are created inside them); the
# sandbox's .claude.json is bind-mounted directly at ~/.claude.json by the wrapper.
if [ -d /state ]; then
    mkdir -p /state/projects /state/todos
    [ -e /state/history.jsonl ] || : > /state/history.jsonl
    ln -sfn /state/projects      "$CLAUDE_HOME/projects"
    ln -sfn /state/todos         "$CLAUDE_HOME/todos"
    ln -sfn /state/history.jsonl "$CLAUDE_HOME/history.jsonl"
fi

# --- Graft host login markers into the sandbox's .claude.json ------------------
# The copied .credentials.json above is enough for non-interactive (`-p`) auth,
# but INTERACTIVE Claude decides whether to show the "how do you want to log in?"
# onboarding screen from markers in ~/.claude.json (hasCompletedOnboarding,
# oauthAccount, userID, ...). Those live in the host's ~/.claude.json, which we
# deliberately DON'T copy wholesale (it's large and full of host project history).
# So we graft ONLY the login/onboarding keys from the read-only seed into the
# sandbox's own (host-separate) .claude.json — just enough for Claude to use the
# seeded credentials silently instead of prompting. Seed values win so a host
# re-login propagates. Written in place (the file is bind-mounted: no mv/rename,
# which would detach the mount) and computed into a var first to avoid truncating
# the file before jq has read it.
CLAUDE_JSON="$(dirname "$CLAUDE_HOME")/.claude.json"
if [ -f /seed/.claude.json ] && command -v jq >/dev/null 2>&1; then
    [ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
    markers="$(jq '{hasCompletedOnboarding, lastOnboardingVersion, oauthAccount, userID, firstStartTime, theme} | with_entries(select(.value != null))' /seed/.claude.json 2>/dev/null || echo '{}')"
    if merged="$(jq --argjson m "$markers" '. * $m' "$CLAUDE_JSON" 2>/dev/null)"; then
        printf '%s\n' "$merged" > "$CLAUDE_JSON"
        echo "[entrypoint] grafted host login markers into ~/.claude.json (no interactive auth prompt)"
    fi
fi

# Treat the bind-mounted workspace as trusted (it's owned by uid 1000 anyway).
git config --global --add safe.directory /workspace
git config --global --add safe.directory '*'

# Route all git hooks through our guard dir so the pre-push main-block applies
# regardless of what the repo ships. Best-effort: real protection is server-side.
git config --global core.hooksPath /etc/claude-isolated/git-hooks

# Give commits an identity. Override via GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL in
# the env file (git also reads those two vars directly when making a commit).
git config --global user.name  "${GIT_AUTHOR_NAME:-claude-isolated}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-claude-isolated@localhost}"
git config --global init.defaultBranch main

# Wire git to authenticate to GitHub over HTTPS using the injected PAT, so the
# agent can fetch/push to allowlisted repos and `gh` works. No token -> no auth
# configured (the agent can still work on local repos / public clones).
if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git 2>/dev/null \
        && echo "[entrypoint] git configured to auth via GH_TOKEN (gh credential helper)" \
        || echo "[entrypoint] WARNING: 'gh auth setup-git' failed; pushes may prompt" >&2
fi

# --- Optional project database (opt-in via /workspace/.claude-isolated.json) --
# Generic, engine-neutral contract: a "database" object with a "type" selects an
# engine (only "postgres" implemented). The server is baked into the image but
# dormant; we start it here only on request. BEST-EFFORT, never fail-closed — a
# database that won't start is a feature failure (warn loudly, keep going), not a
# security breach. Bound to 127.0.0.1, run as the agent uid, data persisted under
# /state keyed per project; none of this touches the egress posture.

start_postgres() {
    local cfg="$1" user name password port
    user="$(jq -r '.database.user // "postgres"' "$cfg")"
    name="$(jq -r --arg u "$user" '.database.name // $u' "$cfg")"
    password="$(jq -r '.database.password // "postgres"' "$cfg")"
    port="$(jq -r '.database.port // 5432' "$cfg")"

    local pgbin=/usr/lib/postgresql/16/bin
    local key="${SANDBOX_PROJECT_KEY:-default}"
    local pgdata="/state/pg/${key}/16"
    local logfile="/state/pg/${key}/postgres-16.log"
    mkdir -p "$pgdata"

    if [ ! -f "$pgdata/PG_VERSION" ]; then
        echo "[entrypoint] initializing Postgres cluster at $pgdata"
        if ! "$pgbin/initdb" -D "$pgdata" -U postgres \
                --auth-local=trust --auth-host=trust >/dev/null 2>&1; then
            echo "[entrypoint] WARNING: initdb failed — project database unavailable" >&2
            return 0
        fi
        # Loopback only (defense in depth) and a writable socket dir for the agent.
        {
            echo "listen_addresses = '127.0.0.1'"
            echo "unix_socket_directories = '/tmp'"
        } >> "$pgdata/postgresql.conf"
    fi

    if ! "$pgbin/pg_ctl" -D "$pgdata" -l "$logfile" -o "-p $port" -w -t 30 start >/dev/null 2>&1; then
        echo "[entrypoint] WARNING: postgres did not start on port $port (concurrent session of this project? see $logfile) — continuing without a database" >&2
        return 0
    fi
    echo "[entrypoint] postgres listening on 127.0.0.1:${port} (data: $pgdata)"

    # Create the requested role + database (idempotent across persistent restarts).
    local q="$pgbin/psql -h 127.0.0.1 -p $port -U postgres -d postgres -tAc"
    if [ "$($q "SELECT 1 FROM pg_roles WHERE rolname='$user'" 2>/dev/null)" != "1" ]; then
        $q "CREATE ROLE \"$user\" LOGIN SUPERUSER PASSWORD '$password'" >/dev/null 2>&1 \
            && echo "[entrypoint] created role '$user'"
    fi
    if [ "$($q "SELECT 1 FROM pg_database WHERE datname='$name'" 2>/dev/null)" != "1" ]; then
        $q "CREATE DATABASE \"$name\" OWNER \"$user\"" >/dev/null 2>&1 \
            && echo "[entrypoint] created database '$name' owned by '$user'"
    fi
}

setup_database() {
    local cfg=/workspace/.claude-isolated.json
    [ -f "$cfg" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # Require a "database" object; absent or false => nothing to do.
    [ "$(jq -r 'try ((.database | type) == "object") catch false' "$cfg" 2>/dev/null)" = "true" ] || return 0

    local dbtype
    dbtype="$(jq -r '.database.type // "postgres"' "$cfg" 2>/dev/null)"
    case "$dbtype" in
        postgres) start_postgres "$cfg" ;;
        *) echo "[entrypoint] WARNING: unsupported database type '$dbtype' in .claude-isolated.json — skipping" >&2 ;;
    esac
}

# Guarded so a database hiccup can never abort phase 2 (set -e is active).
setup_database || true

# Default command: a skip-permissions Claude session in the workspace. The
# proxy + firewall + non-root user are what make that flag safe here.
if [ "$#" -eq 0 ]; then
    set -- claude --dangerously-skip-permissions
fi

exec "$@"
