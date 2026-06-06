# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claude-isolated` runs Claude Code with `--dangerously-skip-permissions` inside a
hardened Docker container so the host doesn't have to trust the agent. There is no
application code, test suite, or package manager here — the repo *is* the sandbox
(a Dockerfile, an entrypoint, a proxy config, and a host wrapper; the egress
allowlist itself is host-side config, not a baked file). Most of the README is
end-user docs; this file is about safely changing
the sandbox itself. Read the README for the full design rationale and threat model.

Target host is **arm64/aarch64**.

## Commands

The "build" is the Docker image build; there are no unit tests — verification is
running the sandbox and watching `docker logs` for squid allow/deny lines.

```sh
# Build (after editing anything baked into the image; run from the repo root)
docker build -t claude-sandbox:latest .

# Bump the pinned Claude Code version
docker build -t claude-sandbox:latest --build-arg CLAUDE_CODE_VERSION=X.Y.Z .

# Run a session (cwd becomes /workspace; args pass through to `claude`)
cd <project> && claude-isolated [claude args...]

# Re-install the host wrapper after editing `claude-isolated` (it is NOT in the image)
sudo install -m 755 ./claude-isolated /usr/local/bin/claude-isolated
```

**What requires what:** editing `Dockerfile`, `entrypoint.sh`, `squid.conf`, or
`git-guard/pre-push` requires a **rebuild** (they are `COPY`ed in). Editing
`claude-isolated` requires **re-installing** the wrapper (it runs on the host).
The egress allowlist and auxiliary mounts are **host-side config**
(`~/.config/claude-isolated/config.json`), read by the wrapper at launch — editing
them needs **neither** a rebuild nor a re-install. Config-only image changes
rebuild in seconds thanks to layer caching.

## Architecture: the security model is the product

The guardrail is the container, not a permission prompt. The pieces interlock —
changing one without understanding the others can silently open the sandbox.

**Two-phase entrypoint** (`entrypoint.sh`). Phase 1 runs as **root**: starts
squid, waits for it to accept connections (**fails closed** — refuses to launch
the agent if the proxy never comes up), programs the iptables egress firewall,
then `runuser`s to the `agent` user and re-execs itself. Phase 2 runs as **agent**
(uid 1000): **verifies the egress posture** (a second fail-closed gate — see
below), assembles `~/.claude`, configures git/gh, and execs Claude. Capabilities
(`NET_ADMIN`, `SETUID`, `SETGID`) are granted only to root in phase 1 and vanish on
the uid change — the agent process holds none.

**Egress self-test** (the second fail-closed gate, phase 2). The proxy-up wait
proves squid is *running*; it does not prove the firewall *contains* the agent.
So before launching Claude, phase 2 probes egress as the agent uid and **refuses
to start** on a breach. Three checks: (1) HARD — a direct connection bypassing
the proxy must be dropped; it uses a literal IP over plain HTTP (`http://1.1.1.1`,
`--noproxy '*'`) so it tests the iptables `OUTPUT` drop and not DNS/TLS — HTTPS
would mask a breach because a failed cert check also exits non-zero. (2) HARD — a
proxied request to a non-allowlisted host must be denied by squid. The canary is a
reserved `*.invalid` host (`sandbox-egress-canary.invalid`): squid denies it on
the `dstdomain` ACL before any DNS (works offline) and no operator could ever
legitimately allowlist it — unlike a real domain like `example.com`, which an
edited allowlist could now contain and falsely trip the gate.
(3) SOFT — a proxied request to an allowlisted host (`api.github.com/zen`) should
succeed; failure only warns, since a stale allowlist or down network surfaces as
a loud Claude error rather than an escape. A firewall or squid misconfig thus
launches nothing instead of silently opening the box.

**Egress chokepoint.** Two independent layers, both must agree:
1. iptables (`OUTPUT` default-DROP) lets *only the `proxy` uid* reach the network
   (DNS + 80/443). The agent's own packets to anything but loopback are dropped.
2. squid (loopback `127.0.0.1:3128`) forwards only to hostnames in
   `/etc/squid/allowlist.txt` (`dstdomain` match) and denies all else; CONNECT is
   restricted to 443 so it can't become a generic TCP relay. That file is **not**
   baked into the image — phase 1 (root) writes it from `SANDBOX_ALLOWLIST` (the
   wrapper passes the host-side config's `domains` in) *before* `squid -f`, since
   squid reads the allowlist once at startup. An empty list → empty file → squid
   denies all (fail closed).

The agent is forced through squid via `HTTP(S)_PROXY` env vars set in the Dockerfile.
So a new outbound host needs **both** an allowlist entry *and* (implicitly) the
port already permitted by iptables — for normal HTTP(S) the ports are covered, so
in practice you only edit `domains` in the host-side config (see below).

**Config isolation** (the host-escape defense). The real host `~/.claude` is
mounted **read-only** at `/seed` and only ever *copied from* — so the agent cannot
plant hooks, settings, plugins, or a malicious `.claude.json` that would later run
in the user's normal Claude sessions. Mutable state worth keeping (conversations,
project memory, history, the sandbox's own `.claude.json`) lives in a **separate**
host dir mounted at `/state`. The entrypoint reconstructs `~/.claude` from `/seed`
+ `/state` at startup; plugins are symlinked read-only from the seed. The
`/seed`-copy skip-list in `entrypoint.sh` (`projects|plugins|todos|...`) is what
keeps bulk/state/read-only paths out of the throwaway copy — keep it in sync if
you change what persists.

`.credentials.json` is *not* on the skip-list, so host credentials are copied in
and `-p` (print-mode) auth works directly. **Interactive** auth additionally
needs login markers (`hasCompletedOnboarding`, `oauthAccount`, `userID`) that
live in the host's `~/.claude.json` — which *is* on the skip-list. The entrypoint
therefore grafts *only those keys* (via `jq '. * $m'`, seed wins) from
`/seed/.claude.json` into the sandbox's own bind-mounted `.claude.json`; it does
not copy the whole file (large, holds host project history). Write it **in place**
(the file is bind-mounted — a `mv`/rename would detach the mount), and compute the
merge into a variable before redirecting, or you truncate the file before `jq`
reads it. (Gotcha found the hard way: `"${var:-{}}"` as a jq `--argjson` default
appends a stray `}` and corrupts the JSON — pass a pre-validated var instead.)

## Project databases (opt-in)

A project can request a sandbox-managed database via a gitignored
`/workspace/.claude-isolated.json` (`{"database":{"type":"postgres",...}}`). Three
pieces interlock:

- **Dockerfile** bakes PostgreSQL (server + client) in **dormant** — the
  `POSTGRES_VERSION` build-arg pins the major; the package's default privileged
  cluster is dropped; the versioned bindir is added to the agent `PATH`.
- **`claude-isolated`** exports `SANDBOX_PROJECT_KEY` (a sha256-derived,
  collision-resistant id for `$PWD`) — the container only sees `/workspace`, so
  the host must supply the key used to namespace persistent data under `/state`.
- **`entrypoint.sh`** phase 2 (`setup_database`) parses the config and, for
  `type=postgres`, inits/starts a **loopback-only** cluster under
  `/state/pg/<key>/<major>` as the agent uid, creating the role+db. It is
  **best-effort, never fail-closed**: a DB that won't start warns and continues
  (the fail-closed gates are for *security*, not features). Because it binds
  `127.0.0.1` and loopback egress is always allowed, it touches none of the
  iptables/squid posture. Adding another engine (e.g. MySQL) is a new `case`
  branch in `setup_database` plus its server package in the Dockerfile — the
  config contract doesn't change.

## Host-side config: egress allowlist + read-only auxiliary mounts

Both the egress allowlist (`domains`) and extra readable host dirs (`mounts`) are
declared in a single **host-side** `~/.config/claude-isolated/config.json`
(override `CLAUDE_ISOLATED_CONFIG`), parsed by `claude-isolated` — **wrapper-only,
no rebuild** (re-install the wrapper only if you change the wrapper itself).
Unlike `/workspace/.claude-isolated.json` (read inside the container,
agent-writable), this file is **never mounted in**, so the agent can neither widen
its own egress nor author its own mounts; that is the whole point. It must
therefore NOT live under `$STATE_DIR` (default `~/.claude-isolated`, mounted rw as
`/state`) or `$CLAUDE_DIR` — either would make it agent-writable and reopen the
hole. Both keys take a top-level array plus per-launch-dir
`projects["<abs>"].{domains,mounts}`, composed additively and validated
**fail-closed** (a bad config aborts the launch — no container).

- **`domains`** — squid `dstdomain` entries (verbatim dot-convention: `.x.com` =
  apex+subdomains, `x.com` = exact). The wrapper **seeds a default set on first
  run** (the file is the single source of truth — there is no baked `allowlist.txt`
  anymore), validates each entry is a plain hostname, dedups, and passes them as
  `SANDBOX_ALLOWLIST`; phase 1 writes them to `/etc/squid/allowlist.txt` before
  squid starts. Editing this is the *only* way to change egress.
- **`mounts`** — `-v <path>:<path>:ro` (same absolute path); add no network path,
  so the egress posture is unchanged. A path that would shadow a container-critical
  dir is rejected (see the `protected` list in the wrapper).

## Editing rules that bite

- **Allowlist overlaps are fatal.** squid refuses to start if an entry overlaps
  another (e.g. both `github.com` and `.github.com`, or `.foo.com` and `a.foo.com`).
  Use **one** broad `.domain` per site. A non-starting squid means a no-network
  (fail-closed) box. This now bites at *config* edit time (`domains` in the
  host-side config), not at image-build time, and the seed default + per-project
  entries can overlap too. Every host added is a potential exfil channel — keep it
  tight. (If you change the seed default list, it lives in the `claude-isolated`
  heredoc, not a baked file.)
- **entrypoint.sh / pre-push must be world-readable (0755), not just executable.**
  A script invoked via its shebang must be *readable* by whoever runs it; `chmod +x`
  on a 0600 file leaves 0711 and phase 2 dies with "Permission denied". The
  Dockerfile sets 0755 explicitly for this reason.
- **squid must run as the `proxy` user.** iptables keys egress on the `proxy` uid;
  if `cache_effective_user proxy` is dropped from `squid.conf`, all outbound
  traffic is dropped and the proxy is useless.
- **The `pre-push` main/master block is best-effort only.** The real guarantee is
  server-side GitHub branch protection; a hijacked agent could edit its own copy.

## Secrets

`GH_TOKEN` and commit identity come from an env file (`--env-file`), default
`~/.config/claude-isolated/env`, scaffolded on first run. Never commit it — the
`.gitignore` blocks `env`, `*.env`, `*.token`, `*.pat`, etc. The PAT should be
fine-grained and scoped to only the repos the sandbox may push to.
