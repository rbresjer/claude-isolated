# claude-isolated

Run Claude Code with `--dangerously-skip-permissions` inside any project
directory **without trusting the agent not to harm the host**. A container — not
a permission prompt — is the guardrail: a non-root agent behind a default-deny
egress firewall, with the only path out being an in-container domain-allowlist
proxy.

```
  container (own net namespace)
  ┌───────────────────────────────────────────────────┐
  │  squid (uid proxy) ── allowlist ──▶ internet        │  iptables:
  │     ▲ 127.0.0.1:3128                                │   only proxy-uid egress
  │     │ (loopback is the only path out)               │   everything else DROP
  │  claude --dangerously-skip-permissions (uid 1000)   │
  │     HTTP(S)_PROXY=http://127.0.0.1:3128             │
  └───────────────────────────────────────────────────┘
```

---

## Contents

- [How it works](#how-it-works)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [1. Build the image](#1-build-the-image)
- [2. Install the wrapper](#2-install-the-wrapper)
- [3. Configure (env file)](#3-configure-env-file)
- [Usage](#usage)
- [Editing the egress allowlist](#editing-the-egress-allowlist)
- [Rebuilding & updating](#rebuilding--updating)
- [Config isolation & persistence](#config-isolation--persistence)
- [Project databases](#project-databases)
- [Read-only auxiliary mounts](#read-only-auxiliary-mounts)
- [Playwright](#playwright)
- [Environment-variable overrides](#environment-variable-overrides)
- [Resource limits](#resource-limits)
- [Troubleshooting](#troubleshooting)
- [Residual risks](#residual-risks)

---

## How it works

**Egress.** The agent process runs non-root (uid 1000) with `HTTP(S)_PROXY`
pointed at an in-container squid on `127.0.0.1:3128`. iptables sets `OUTPUT` to
default-DROP and only lets the `proxy` uid reach the network (DNS + 80/443).
So the agent's packets to anything but loopback are dropped, and the only real
egress is squid's — which forwards **only** to the hostnames in your host-side
allowlist (`dstdomain` match; see [Editing the egress
allowlist](#editing-the-egress-allowlist)) and denies everything else. It
**fails closed** at two
gates: first the entrypoint refuses to start unless squid is accepting
connections, then — as the agent uid itself — it actively probes the egress
posture and aborts on any security-relevant surprise. The probe runs three
checks: a direct connection bypassing the proxy **must** be dropped (tests the
iptables rule), a proxied request to a non-allowlisted host **must** be denied
by squid (tests deny-all), and a proxied request to an allowlisted host should
succeed (a soft warning, since a stale allowlist surfaces as a loud Claude error
anyway). So there's never a window with network but no filter, and a botched
firewall or proxy config launches nothing instead of silently opening the box.

**Capabilities.** The container drops all Linux capabilities except three the
**root** entrypoint needs transiently: `NET_ADMIN` (program iptables) and
`SETUID`/`SETGID` (drop root → the `proxy` and `agent` users). All three vanish
the instant root becomes the agent — changing uid clears a process's
capabilities — so the unprivileged agent holds none of them (verified:
`CapEff: 0000000000000000`). Plus `--security-opt no-new-privileges`, no docker
socket, no host network namespace.

**Filesystem.** Only the current project directory is bind-mounted read-write
(`/workspace`). Your host config (`~/.claude`) is mounted **read-only** and
copied from, never written. See [Config isolation & persistence](#config-isolation--persistence).

## Files

| File | Role |
|---|---|
| `Dockerfile` | arm64 image: squid, Python, gh, Playwright/Chromium, Claude Code, non-root `agent` (uid 1000) |
| `squid.conf` | filtering forward proxy — allow allowlisted `dstdomain`, deny all (the allowlist itself is host-side config, written in at startup) |
| `entrypoint.sh` | root phase (write the allowlist, start proxy + program iptables) → agent phase (verify egress posture, assemble `~/.claude`, git/gh, run Claude) |
| `git-guard/pre-push` | rejects pushes to `main`/`master` (convenience; real guard is branch protection) |
| `claude-isolated` | host wrapper — a plain `docker run`, one ephemeral container per session |

> Everything **except `claude-isolated`** is baked into the image at build time.
> Editing any of them requires a [rebuild](#rebuilding--updating). Editing
> `claude-isolated` itself requires re-installing the wrapper.

## Prerequisites

- Docker (rootless or daemon), usable without sudo.
- An **arm64 / aarch64** host (the image is built for arm64).
- An authenticated host `~/.claude` (so credentials can be seeded into the box).

## 1. Build the image

Clone the repo and build from its root (the commands below assume you're in the
repo root):

```sh
git clone https://github.com/rbresjer/claude-isolated.git
cd claude-isolated
docker build -t claude-sandbox:latest .
```

The Claude Code version is pinned via a build arg (`CLAUDE_CODE_VERSION`,
default `2.1.161`); override with `--build-arg CLAUDE_CODE_VERSION=X.Y.Z`. The
pnpm version is likewise pinned (`PNPM_VERSION`, default `11.5.1`) — a concrete
version rather than the `latest` tag so corepack resolves it from the baked-in
cache offline instead of re-fetching it from the npm registry on every `pnpm`
invocation.

## 2. Install the wrapper

Put `claude-isolated` on your `PATH` (pick one):

```sh
sudo install -m 755 ./claude-isolated /usr/local/bin/claude-isolated
# or, no sudo:
install -m 755 ./claude-isolated ~/.local/bin/claude-isolated
```

The installed copy is independent of the source — re-run this after editing
`claude-isolated`.

## 3. Configure (env file)

The first run scaffolds a template at `~/.config/claude-isolated/env` and exits.
Fill it in:

- **`GH_TOKEN`** — a **fine-grained** GitHub PAT scoped to the exact repos the
  sandbox may push to (`contents:rw`, `pull_requests:rw`). Leave blank for
  local/public-only work.
- **`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`** — commit identity (git reads these
  directly when committing).
- **`CLAUDE_CODE_OAUTH_TOKEN`** *(recommended)* — a long-lived (one-year, static)
  token from `claude setup-token`, run once on the host. Without it, sessions fall
  back to the credentials seeded from your host `~/.claude` — which go stale: the
  seeded copy is one-way, OAuth access tokens last ~8 h and refreshing **rotates**
  the refresh token inside the container's throwaway copy, revoking the host's.
  The visible symptom is any *new* session (host or sandbox) asking you to log in
  again whenever some sandbox session has run longer than ~8 h. The setup-token
  has no refresh flow, so any number of concurrent containers can share it without
  invalidating each other or your host login. It authenticates against your Claude
  **subscription** (Pro/Max/Team/Enterprise), not pay-per-token API billing — just
  don't also set `ANTHROPIC_API_KEY` here, which would take precedence *and* bill
  per token.

The file is the container's `--env-file`, so any `VAR=value` line is passed in.

## Usage

```sh
cd <project>
tmux new            # one session per sandbox; run as many as you like
claude-isolated     # drops you into a skip-permissions Claude session

claude-isolated --resume          # any args are passed straight to `claude`
claude-isolated -p "explain this" # one-shot print mode
```

Edits land in `<project>` on the host (owned by your user). Concurrent sessions
in different directories don't collide — the proxy is loopback-only, the
container is `--rm` (no fixed name/port), and your host `~/.claude` is read-only.
Persistent state goes to a shared, host-separate dir (see below).

## Editing the egress allowlist

The allowlist is the **only** way out of the sandbox, and it lives in the
**host-side** config file — `~/.config/claude-isolated/config.json` (override with
`CLAUDE_ISOLATED_CONFIG`), the same file that drives [read-only auxiliary
mounts](#read-only-auxiliary-mounts). It is **never mounted into the container**,
so a compromised agent cannot widen its own egress; control stays on the host. On
first run the wrapper **seeds it** with a sensible default set of domains, so
there's one clear, transparent list to edit — **no rebuild** to add a host:

```json
{
  "domains": [".anthropic.com", ".github.com", "pypi.org"],
  "projects": {
    "/data/testdrive-manager": { "domains": [".cupra.com"] }
  }
}
```

- `domains` (top level) — allowed for **every** session.
- `projects["<abs path>"].domains` — allowed only when you launch from that exact
  directory. The effective set is global ∪ per-project, de-duplicated. Add a
  domain, re-run `claude-isolated` — the new image is not needed.

Rules and gotchas:

- One destination per entry. A **leading dot** (`.npmjs.org`) matches the domain
  **and all subdomains, including the apex** (`npmjs.org` and `registry.npmjs.org`
  both match). A bare host (`pypi.org`) matches exactly.
- **Do not list a domain and something it already covers** — e.g. both
  `github.com` and `.github.com`, or `.foo.com` and `a.foo.com`. squid treats
  that as a fatal config error and **won't start** (which, fail-closed, means the
  box has no network). Use a single `.domain` wildcard per site.
- Entries are **validated fail-closed**: anything that isn't a plain
  hostname/domain (whitespace, a slash, `:`, `@`, …) **aborts the launch**.
- Every host you add is a potential exfiltration channel for a hijacked agent —
  keep the list tight.
- squid logs allow/deny decisions to the container's stdout, so `docker logs`
  (or the live session output) shows exactly which host was refused.
- **The default list does not auto-update.** Once your `config.json` exists, a
  newer sandbox version that adds a default host won't reach it. To re-seed,
  delete the `domains` key (or the whole file) and re-run.

## Rebuilding & updating

**Rebuild the image** whenever you change anything baked into it — `squid.conf`,
`Dockerfile`, `entrypoint.sh`, or `git-guard/pre-push`:

```sh
docker build -t claude-sandbox:latest .
```

Layers are cached, so config-only changes (squid/entrypoint) rebuild in seconds.
The next `claude-isolated` invocation uses the new image automatically. (Editing
the [egress allowlist](#editing-the-egress-allowlist) or [auxiliary
mounts](#read-only-auxiliary-mounts) needs **no rebuild** — they're host-side
config read by the wrapper at launch.)

**Re-install the wrapper** whenever you change `claude-isolated` itself (it's a
host-side copy, not part of the image):

```sh
sudo install -m 755 ./claude-isolated /usr/local/bin/claude-isolated
```

**Bump Claude Code (or pnpm):**

```sh
docker build -t claude-sandbox:latest --build-arg CLAUDE_CODE_VERSION=X.Y.Z .
docker build -t claude-sandbox:latest --build-arg PNPM_VERSION=X.Y.Z .
```

## Config isolation & persistence

Your real `~/.claude` is mounted **read-only** (as `/seed`) and only ever copied
*from*. At startup the entrypoint assembles the agent's `~/.claude`:

- **Config** (settings, hooks, skills, commands, `CLAUDE.md`, credentials) —
  copied from the read-only seed into a throwaway in-container copy. The agent
  may edit its copy, but **your host config is physically unwritable**, so it
  cannot plant hooks/settings or a malicious `.claude.json` that would later run
  in your normal Claude sessions.
- **Plugins** — symlinked **read-only** straight from the host seed (no copy).
- **Conversations, project memory, command history, the sandbox's own
  `.claude.json`** — live in a **separate** host dir (`$STATE_DIR`, default
  `~/.claude-isolated`; override with `CLAUDE_ISOLATED_STATE`). These
  **persist across runs** and are shared between sandbox sessions, but are kept
  entirely apart from your real `~/.claude`. Inspect or wipe that dir freely;
  it's created automatically on first run.
- **pnpm store** — pointed at `$STATE_DIR/pnpm/store` so package downloads are
  cached across sessions (shared between all projects; the store is
  content-addressed, so this is safe and dedupes). Your host's own pnpm store is
  never mounted and isn't writable by the agent, and a project's `node_modules`
  may even record that stale host path — so if `pnpm add`/`pnpm install` ever
  complains about the store, a plain **`pnpm install`** (or
  `rm -rf node_modules && pnpm install`) relinks cleanly into this writable store.
  That reinstall is deterministic from the lockfile — it is the normal fix, not a
  workaround.
- **Login markers** (`hasCompletedOnboarding`, `oauthAccount`, `userID`, …) —
  grafted from the host's `~/.claude.json` into the sandbox's own `.claude.json`
  at startup, so interactive Claude recognizes the seeded credentials and skips
  the "how do you want to log in?" onboarding screen. Only these few keys are
  copied — **not** the host's full `.claude.json` (which is large and holds your
  host project history). A host re-login propagates on the next sandbox run.
- **Seeded credentials go stale by design** — the copy is one-way (the seed is
  read-only), so when a session outlives the ~8 h OAuth access token, Claude
  refreshes it *inside the throwaway copy*; the rotation revokes the host's
  refresh token and the next new session prompts for login. Set
  `CLAUDE_CODE_OAUTH_TOKEN` in the env file to opt out of seeded credentials
  entirely (see [Configure (env file)](#3-configure-env-file)).

What does **not** persist: changes to global config (settings / hooks /
`CLAUDE.md` / plugins) — by design, since those are the host-escape vectors.

## Project databases

Some projects need a database (often run via `docker compose` outside the
sandbox). Docker isn't available inside the container — and Docker-in-Docker
would break the isolation model — but a database server is just a process on a
port, and **loopback traffic inside the container is unrestricted**, so a
sandbox-managed database needs no change to the egress firewall.

The image ships PostgreSQL 16 **dormant**. The common case needs **zero config**:
if the project's `DATABASE_URL` points at a **local** Postgres (`localhost` /
`127.0.0.1`), the entrypoint auto-detects it on launch and brings up a cluster
whose role/database/password/port **match the URL**, so migrations connect
straight away. The URL is read from the process env, then `.env`, `.env.local`,
and `.env.development` (what Prisma & friends read). A URL pointing at a *remote*
host is left untouched — that's someone else's server, not ours to start.

For full control (or a non-default engine selector) a project can still opt in
explicitly with a gitignored `/workspace/.claude-isolated.json`, which takes
precedence over auto-detection. Set `"database": false` to **opt out** of
auto-detection entirely:

```json
{
  "database": {
    "type": "postgres",
    "name": "myapp",
    "user": "myapp",
    "password": "myapp",
    "port": 5432
  }
}
```

On launch the entrypoint inits (first run) and starts a loopback-only cluster,
creating the role and database, so your app's `DATABASE_URL=postgresql://myapp:myapp@localhost:5432/myapp`
just works. Reach it from inside the sandbox with `psql -h localhost -p 5432`
(not `docker exec`).

**Fields** (all optional; an explicit `database` object overrides auto-detection,
`"database": false` disables it):

| Key        | Default              | Notes                                          |
|------------|----------------------|------------------------------------------------|
| `type`     | `postgres`           | engine selector; only `postgres` is implemented (an unknown value warns and is skipped) |
| `user`     | `postgres`           | created with LOGIN + dev superuser             |
| `name`     | the resolved `user`  | database name, owned by `user`                 |
| `password` | `postgres`           | set on the user                                |
| `port`     | `5432`               | TCP port the server listens on (loopback only) |

**Persistence.** Data persists **per project** under the host-separate `/state`
dir (keyed to the project path), so you migrate/seed once and it's there next
launch. Migrations and seeds remain your project's job — run them normally
against `localhost`.

**Caveats.**
- Two concurrent sandbox sessions of the *same* project collide on the data dir
  (the second one's database won't start and logs a warning) — same limitation as
  the per-project dev-server port lanes.
- A database that fails to start never aborts the session; it logs a `WARNING`
  and Claude launches anyway, so you can debug it.

**Gitignore the config file.** Add `.claude-isolated.json` to the project's
`.gitignore` — it carries local credentials and is sandbox-specific.

**Per-project recipe.** With a local `DATABASE_URL` in the project's `.env`, no
config file is needed — the cluster is auto-provisioned to match. If you want to
spell it out for a future agent session, drop a note in *that project's*
`CLAUDE.md`, e.g.:

> This project uses a sandbox-managed Postgres, auto-started from `DATABASE_URL`.
> On launch, run the project's migrate + seed scripts, then reach the DB with
> `psql -h localhost`. (To override the auto-detected settings, add
> `.claude-isolated.json` with a `{"database":{...}}` block.)

## Read-only auxiliary mounts

A session sees only `/workspace`. To let the agent **read** other host
directories (e.g. a sibling project for cross-referencing), declare them in a
**host-side** config file — `~/.config/claude-isolated/config.json` (override
with `CLAUDE_ISOLATED_CONFIG`). This is the same file that holds the [egress
allowlist](#editing-the-egress-allowlist) (`domains`); it is **never mounted into
the container**, so the agent cannot grant itself new read access; control stays
on the host. (Do not place it under `$STATE_DIR`/`$CLAUDE_DIR` — those are
reachable by the agent.)

```json
{
  "mounts": ["/data/shared-lib"],
  "projects": {
    "/data/testdrive-manager": { "mounts": ["/data/testdrive-planner"] }
  }
}
```

- `mounts` (top level) — mounted for **every** session.
- `projects["<abs path>"].mounts` — mounted only when you launch from that exact
  directory. The effective set is global ∪ per-project, de-duplicated.

Each path is mounted **read-only at the same absolute path**, so the agent reads
it where it lives on the host (`cat /data/testdrive-planner/README.md`). Writes
fail with `Read-only file system`. None of this touches the egress firewall.

**Validation is fail-closed.** `jq` is required. A config that is present but
invalid — bad JSON, `mounts` not an array of strings, a non-absolute or
non-existent path, or a path that would shadow a container-critical directory
(`/`, or equal-to/ancestor-of `/home /home/agent /etc /usr /bin /sbin /lib
/lib64 /var /tmp /root /opt /boot /run /dev /proc /sys /workspace /seed /state`)
— **aborts the launch**. A *missing* config file is fine (it just means no extra
mounts). Subdirectories such as `/data/...` or `/home/<you>/projects/foo` are
allowed.

**Caveat.** The agent reads as uid 1000; the host files must be readable by that
uid (or group/other). `projects` keys match the literal launch path (`$PWD`).

## Playwright

Chromium is bundled and runs headless. Driving **localhost** (an in-container dev
server) works out of the box. To reach an **allowlisted external** host, pass the
proxy to the browser explicitly — Chromium does not pick up `HTTPS_PROXY` from the
environment the way curl/git do:

```js
await chromium.launch({ proxy: { server: 'http://127.0.0.1:3128' } });
```

Navigating to a **non-allowlisted** host fails closed either way (the firewall
drops the agent's direct connection; the proxy refuses the domain).

## Environment-variable overrides

Set these in your shell before running `claude-isolated`:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_ISOLATED_IMAGE` | `claude-sandbox:latest` | Image to run |
| `CLAUDE_ISOLATED_ENV` | `~/.config/claude-isolated/env` | env file (`GH_TOKEN`, identity, …) |
| `CLAUDE_ISOLATED_CLAUDE_DIR` | `~/.claude` | Host config dir, mounted read-only as the seed |
| `CLAUDE_ISOLATED_STATE` | `<dir of config>/.claude-isolated` | Persistent, host-separate state dir |
| `CLAUDE_ISOLATED_CPUS` | `1.5` | CPU limit per container |

## Resource limits

Each container runs with `--pids-limit 512`, `--memory 4g`, and
`--cpus 1.5` (overridable via `CLAUDE_ISOLATED_CPUS`) so a runaway session can't
starve the host. The default leaves headroom for several concurrent sessions on a
2-core host.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `image '…' not found` | Build it from the repo root: `docker build -t claude-sandbox:latest .` |
| `created env template … then re-run` | Expected on first run — fill in `~/.config/claude-isolated/env` |
| A needed download/host fails | Not allowlisted. Add it to `domains` in `~/.config/claude-isolated/config.json` and re-run (no rebuild). Check `docker logs` for the squid deny line. |
| Container exits immediately, squid `FATAL` about a `dstdomain` | Overlapping allowlist entries (a domain and its subdomain). Collapse to one `.domain`. |
| New session (host or sandbox) asks to log in again | A sandbox session ran >8 h and rotated the OAuth token in its throwaway copy, revoking the host's. Set `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) in the env file — see [Configure (env file)](#3-configure-env-file). |
| Playwright can't reach an external (allowlisted) site | Pass `proxy: { server: 'http://127.0.0.1:3128' }` to `chromium.launch()` |
| terraform MCP logs an error | Expected — it's a docker-image MCP and there's no docker socket in the box. Claude continues. |
| Push to `main` rejected | Working as intended (`pre-push` guard). Push a `feat/*` branch and open a PR. |

## Residual risks

1. The PAT is readable by the agent (it must be, to push) — fine-grained + repo
   scoped + server-side branch protection bound the blast radius.
2. The `pre-push` main-block is best-effort (a malicious agent could edit its own
   copy); GitHub **branch protection** is the real guarantee.
3. Credentials are copied into the box (the agent needs them to reach the API);
   a hijacked agent can read them. Same exposure as any authenticated session.
4. Concurrent sandboxes share `$STATE_DIR` — low risk (transcripts are keyed by
   workspace and session id), but the shared `.claude.json` can still race.
5. The terraform MCP (a docker-image MCP) can't run in-sandbox (no docker socket,
   by design) — it logs an error and Claude continues. Playwright's browser may
   also skew if an MCP pulls a different Playwright version via npx.
6. Shared kernel (Docker, not a VM): a kernel exploit could still escape. Accepted
   tradeoff given no VM/gVisor on the host.
