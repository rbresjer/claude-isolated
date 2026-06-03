# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claude-isolated` runs Claude Code with `--dangerously-skip-permissions` inside a
hardened Docker container so the host doesn't have to trust the agent. There is no
application code, test suite, or package manager here — the repo *is* the sandbox
(a Dockerfile, an entrypoint, a proxy config, an egress allowlist, and a host
wrapper). Most of the README is end-user docs; this file is about safely changing
the sandbox itself. Read the README for the full design rationale and threat model.

Target host is **arm64/aarch64**.

## Commands

The "build" is the Docker image build; there are no unit tests — verification is
running the sandbox and watching `docker logs` for squid allow/deny lines.

```sh
# Build (after editing anything baked into the image)
docker build -t claude-sandbox:latest /data/dev/claude-docker

# Bump the pinned Claude Code version
docker build -t claude-sandbox:latest --build-arg CLAUDE_CODE_VERSION=X.Y.Z /data/dev/claude-docker

# Run a session (cwd becomes /workspace; args pass through to `claude`)
cd <project> && claude-isolated [claude args...]

# Re-install the host wrapper after editing `claude-isolated` (it is NOT in the image)
sudo install -m 755 /data/dev/claude-docker/claude-isolated /usr/local/bin/claude-isolated
```

**What requires what:** editing `Dockerfile`, `entrypoint.sh`, `squid.conf`,
`allowlist.txt`, or `git-guard/pre-push` requires a **rebuild** (they are `COPY`ed
in). Editing `claude-isolated` requires **re-installing** the wrapper (it runs on
the host). Config-only changes rebuild in seconds thanks to layer caching.

## Architecture: the security model is the product

The guardrail is the container, not a permission prompt. The pieces interlock —
changing one without understanding the others can silently open the sandbox.

**Two-phase entrypoint** (`entrypoint.sh`). Phase 1 runs as **root**: starts
squid, waits for it to accept connections (**fails closed** — refuses to launch
the agent if the proxy never comes up), programs the iptables egress firewall,
then `runuser`s to the `agent` user and re-execs itself. Phase 2 runs as **agent**
(uid 1000): assembles `~/.claude`, configures git/gh, and execs Claude. Capabilities
(`NET_ADMIN`, `SETUID`, `SETGID`) are granted only to root in phase 1 and vanish on
the uid change — the agent process holds none.

**Egress chokepoint.** Two independent layers, both must agree:
1. iptables (`OUTPUT` default-DROP) lets *only the `proxy` uid* reach the network
   (DNS + 80/443). The agent's own packets to anything but loopback are dropped.
2. squid (loopback `127.0.0.1:3128`) forwards only to hostnames in `allowlist.txt`
   (`dstdomain` match) and denies all else; CONNECT is restricted to 443 so it
   can't become a generic TCP relay.

The agent is forced through squid via `HTTP(S)_PROXY` env vars set in the Dockerfile.
So a new outbound host needs **both** an allowlist entry *and* (implicitly) the
port already permitted by iptables — for normal HTTP(S) the ports are covered, so
in practice you only edit `allowlist.txt`.

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

## Editing rules that bite

- **Allowlist overlaps are fatal.** squid refuses to start if an entry overlaps
  another (e.g. both `github.com` and `.github.com`, or `.foo.com` and `a.foo.com`).
  Use **one** broad `.domain` per site. A non-starting squid means a no-network
  (fail-closed) box. Every host added is a potential exfil channel — keep it tight.
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
