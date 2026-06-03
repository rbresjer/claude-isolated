# Per-project database opt-in for the claude-isolated sandbox

**Date:** 2026-06-03
**Status:** Approved design, pending implementation plan

## Problem

The sandbox image is generic and carries no application code. Projects that need
a database (e.g. a Postgres backing a web app) normally bring it up with
`docker compose`, but Docker is not available inside the container — and running
Docker-in-Docker would require either `--privileged` or mounting the host Docker
socket, both of which hand the agent control of the host daemon and blow a hole
through the egress/host-escape containment that is the entire point of this repo.

A database server, however, does not need Docker. It is just a process listening
on a port. Bound to loopback inside the container it is fully reachable by the
app (iptables already allows all loopback traffic unconditionally) with **no**
change to the egress model — no new firewall rules, no allowlist entries, no
squid changes.

## Goal

Let a project opt into a sandbox-managed database by dropping a single gitignored
config file in its working directory. The image stays generic: it *ships* the DB
server but only *starts* one when a project asks for it. The contract is
engine-neutral so additional engines (e.g. MySQL) can be added later without a
breaking change. Postgres is the only engine implemented now.

## Config contract

A gitignored `/workspace/.claude-isolated.json`. Database config is namespaced
under `database` so the file can hold future sandbox-feature toggles:

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

Keys are engine-neutral (`type` / `name` / `user` / `password` / `port` map
cleanly onto Postgres and MySQL alike). All keys are optional except that a
`database` object must be present to trigger anything:

| Key        | Default            | Notes                                            |
|------------|--------------------|--------------------------------------------------|
| `type`     | `postgres`         | dispatch key; only `postgres` implemented        |
| `user`     | `postgres`         | role/user created with LOGIN + dev superuser     |
| `name`     | the resolved `user`| database name, owned by `user`                   |
| `password` | `postgres`         | set on the user                                  |
| `port`     | engine default (5432) | TCP port the server listens on (loopback)     |

If `.database` is absent (or `false`), the entrypoint does nothing — **zero
overhead for non-database projects**. The entrypoint dispatches on
`.database.type`: `postgres` runs the flow below; any other value hits a
`"unsupported database type 'X'"` warn-and-continue branch. Adding an engine
later is a new branch plus its server package in the image — not a contract
change.

## Architecture

Three files change. Each piece has one clear responsibility.

### 1. Dockerfile — ship the server, dormant

- Add the PGDG apt repo; install `postgresql-16` + `postgresql-client-16`
  (client included so the agent can `psql`), behind a `POSTGRES_VERSION=16`
  build-arg.
- The Debian package auto-creates a root/`postgres`-owned cluster that we never
  use; `pg_dropcluster 16 main` at build drops it to avoid confusion.
- Add `/usr/lib/postgresql/16/bin` to the agent `PATH` via `ENV`.
- Cost: a few hundred MB, dormant unless a project opts in.

### 2. claude-isolated (host wrapper) — supply the project identity

The container only ever sees `/workspace`; it cannot derive the host project
path needed to key per-project persistent data. So the wrapper exports one new,
engine-neutral env var:

- `SANDBOX_PROJECT_KEY` — a stable identifier for `$PWD`: `sha256` of the path,
  first ~12 hex chars, prefixed with the basename for readability
  (e.g. `myapp-9f3a1c2b4d5e`).

A stronger hash than the existing port-lane `cksum` is used deliberately: a
data-dir collision would silently mix two projects' databases, which is worse
than a port clash. No database-specific logic lives on the host — config parsing
stays solely in the entrypoint (single source of truth).

### 3. entrypoint.sh (phase 2, agent uid) — init + start

A new **best-effort** step, after the egress self-test and before `exec`-ing
Claude. It is **not** a fail-closed gate: the fail-closed gates protect
*security*; a database that will not start is a *feature* failure, so it warns
loudly and still launches Claude (same posture as the soft allowlist check and
`gh auth`), letting the agent debug rather than bricking the session. The whole
step is guarded so a failure never aborts phase 2 (`set -e` is active).

Flow when `.database` requests `postgres`:

1. Parse the config with `jq` (already in the image); resolve params + defaults.
2. `PGDATA = /state/pg/<SANDBOX_PROJECT_KEY>/<pg-major>`. The project-key segment
   namespaces per project (`/state` is shared across all projects); the
   major-version segment means a future `POSTGRES_VERSION` bump inits a fresh
   cluster instead of failing on an incompatible one.
3. If `PGDATA` is not yet initialized (no `PG_VERSION` file) → `initdb` as the
   agent user; then create the role (LOGIN + dev superuser, password set) and the
   database (owned by the role). Idempotent: on a persistent dir it detects an
   existing role/db and skips creation.
4. Configure `listen_addresses='127.0.0.1'` (loopback only — defense in depth),
   the chosen `port`, and a `pg_hba` that trusts loopback. Start via `pg_ctl -w`
   (wait-for-ready), logging to a file under the data dir.
5. `exec` Claude as today.

## Persistence & concurrency

- Data persists per project in `/state` (the existing host-separate, persistent,
  rw-mounted dir — no new host surface; we add a subtree, not a new mount). You
  migrate + seed once and it is there next launch.
- Two concurrent sessions of the **same** project collide on the data dir / port
  (the second `pg_ctl start` fails and warns) — the same documented limitation as
  the existing per-project port lanes. Distinct projects never collide.
- A `POSTGRES_VERSION` bump starts a fresh cluster under a new major-version dir;
  old data remains under the old dir for manual cleanup.

## Security analysis

The egress chokepoint and host-escape defenses are untouched:

- **Loopback only.** Postgres binds `127.0.0.1`. Loopback is already
  unconditionally allowed by iptables; no new `OUTPUT`/`INPUT` rules, no allowlist
  entries, no squid changes. Not reachable off-box.
- **No privilege.** `initdb` / `pg_ctl` / `postgres` all run as the `agent` uid
  (1000). No root, no new privileged user. The package's default privileged
  cluster is dropped at build.
- **No new host surface.** Data lives under `/state`, already mounted rw and
  host-separate.
- **Config grants no new power.** `.claude-isolated.json` sits in `/workspace`,
  already fully agent-controlled — reading it lets the agent start a DB it could
  have started by hand anyway. Nothing escalates.

The only new failure mode is "DB did not start," contained to a warning.

## Documentation

All documentation in this repo is **generic** — no project-specific content.

1. **README** — new "Project databases" section: the mechanism, the
   `.claude-isolated.json` schema and defaults, persistence/concurrency behavior,
   supported `type` values, and a **copy-paste template with placeholders** that
   any project can refer to and fill in for itself (including the reminder to
   gitignore the file and to reach the DB at `localhost:<port>` rather than via
   Docker).
2. **CLAUDE.md** (this repo) — a short note for whoever edits the sandbox itself,
   explaining how the Dockerfile / wrapper / entrypoint pieces interlock for this
   feature, consistent with the existing "security model is the product" style.

Per-project wiring (what DB name/user a given project uses, when to run its
migrations/seeds) lives in **that project's** own `CLAUDE.md`, authored per
project by referring to the generic README template. It is explicitly **out of
scope** for this repo.

## Out of scope (YAGNI)

- MySQL or any non-Postgres engine implementation (contract is ready; the branch
  and package are not built until needed).
- Lifecycle hooks (auto-running migrations/seeds from the entrypoint) — migrations
  and seeds stay the project's job, run normally against `localhost`.
- A strict/fail-closed mode for DB startup — warn-and-continue only.
- Any project-specific configuration or docs in this repo.

## Edge cases & notes

- Clients that send a password still work against a loopback-`trust` `pg_hba`
  (libpq accepts `trust` even when a password is supplied); the role password is
  also set so password-requiring clients are satisfied.
- Postgres is crash-safe (WAL), so an abrupt container stop (`docker run --rm`) is
  recoverable on next start.
- `psql` from the project's docs that used `docker exec ... psql` becomes
  `psql -h localhost` inside the sandbox — a project-side note, not a sandbox
  change.
