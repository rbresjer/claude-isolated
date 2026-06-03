# Per-project database opt-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project opt into a sandbox-managed, loopback-only database by dropping a gitignored `.claude-isolated.json` in its working directory; the generic image ships Postgres but only starts it on request.

**Architecture:** The Dockerfile bakes a dormant Postgres 16 server+client into the image. The host wrapper passes a stable per-project key so persistent data can be namespaced under `/state`. The entrypoint (phase 2, agent uid) reads the workspace config and — best-effort, never fail-closed — inits and starts a loopback-only cluster, creating the requested role+db. The contract is engine-neutral (`database.type`) so other engines can be added later.

**Tech Stack:** Bash (entrypoint + wrapper), Docker (Debian bookworm base), PostgreSQL 16 (PGDG apt repo), `jq` (config parsing, already in image).

**Verification model:** This repo has no unit-test suite — verification is *building the image and observing `docker run` / log output*, per the repo's own `CLAUDE.md`. Each task's "Verify" is a real build/run command with expected output, not a test framework invocation.

---

### Task 1: Bake a dormant Postgres 16 into the image

**Goal:** The image contains the Postgres 16 server + client, on the agent's PATH, with the package's default privileged cluster removed and the version controlled by a build-arg.

**Files:**
- Modify: `Dockerfile` (OS-packages area, currently lines ~14–37; runtime env around lines ~88–94)

**Acceptance Criteria:**
- [ ] `docker build` succeeds on arm64.
- [ ] `initdb`, `pg_ctl`, and `psql` all resolve on the agent's PATH inside the container.
- [ ] The Debian default cluster (`/etc/postgresql/16/main`) does not exist.
- [ ] Postgres major version is set by `--build-arg POSTGRES_VERSION=16`.

**Verify:**
```sh
docker build -t claude-sandbox:latest /data/dev/claude-docker
docker run --rm --entrypoint bash claude-sandbox:latest -lc \
  'runuser -u agent -- bash -lc "which initdb pg_ctl psql && ls /etc/postgresql/16/main 2>&1 || echo NO-DEFAULT-CLUSTER"'
```
Expected: three binary paths printed, then `NO-DEFAULT-CLUSTER`.

**Steps:**

- [ ] **Step 1: Add a `POSTGRES_VERSION` build-arg** next to the existing `CLAUDE_CODE_VERSION` arg (after line 10):

```dockerfile
# Pin the Postgres major version baked in for project databases (opt-in at runtime).
ARG POSTGRES_VERSION=16
```

- [ ] **Step 2: Add the PGDG repo + Postgres install as a new RUN block** immediately after the existing apt/gh install block (after current line 37, before the corepack block). The PGDG repo is required because Debian bookworm's default Postgres is 15, not 16:

```dockerfile
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
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Put the versioned bindir on PATH** by extending the runtime `ENV` block (current lines ~88–94). Add a `PATH` line (keep the existing proxy vars):

```dockerfile
ENV HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    http_proxy=http://127.0.0.1:3128 \
    https_proxy=http://127.0.0.1:3128 \
    NO_PROXY=localhost,127.0.0.1,::1 \
    no_proxy=localhost,127.0.0.1,::1 \
    DISABLE_AUTOUPDATER=1 \
    PATH=/usr/lib/postgresql/16/bin:$PATH
```

Note: the `PATH` bindir is hard-coded to `16` to match the default build-arg. If you override `POSTGRES_VERSION`, update this segment too (a literal is used because `ENV` cannot reference an `ARG` mid-string portably across the cached layer).

- [ ] **Step 4: Build and verify** using the Verify command above. Confirm the three binaries resolve and `NO-DEFAULT-CLUSTER` prints.

- [ ] **Step 5: Commit**

```sh
git add Dockerfile
git commit -m "Bake a dormant Postgres 16 into the sandbox image"
```

---

### Task 2: Pass a stable per-project key from the host wrapper

**Goal:** `claude-isolated` exports `SANDBOX_PROJECT_KEY` (a stable, collision-resistant identifier for `$PWD`) into the container, so the entrypoint can namespace persistent DB data per project.

**Files:**
- Modify: `claude-isolated` (after the state-dir prep block ~lines 58–63; and the `docker run` env list ~lines 115–127)

**Acceptance Criteria:**
- [ ] Running the wrapper's key computation for a given path yields a stable `basename-<12hexsha>` string.
- [ ] Distinct paths yield distinct keys; the basename is sanitized to `[A-Za-z0-9._-]`.
- [ ] The value is passed to the container as `SANDBOX_PROJECT_KEY`.

**Verify:**
```sh
cd /tmp && PWD_TEST=/data/dev/testdrive-manager \
  bash -c 'b="$(basename "$PWD_TEST" | tr -c "A-Za-z0-9._-" "_")"; h="$(printf "%s" "$PWD_TEST" | sha256sum | cut -c1-12)"; echo "${b}-${h}"'
```
Expected: a line like `testdrive-manager-<12 hex chars>`, identical across repeated runs.

**Steps:**

- [ ] **Step 1: Compute the key** — insert after the state-dir prep block (after current line 63), before the dev-server ports block:

```bash
# --- Stable per-project identity ---------------------------------------------
# The container only ever sees /workspace, so it cannot derive the host project
# path needed to key per-project persistent state (e.g. a database data dir under
# /state). Compute a stable key here and pass it in. A sha256 (not the port-lane
# cksum) because a DB-dir collision would silently mix two projects' data, which
# is worse than a port clash. Basename prefix is for human readability only.
project_base="$(basename "$PWD" | tr -c 'A-Za-z0-9._-' '_')"
project_hash="$(printf '%s' "$PWD" | sha256sum | cut -c1-12)"
PROJECT_KEY="${project_base}-${project_hash}"
```

- [ ] **Step 2: Pass it into the container** — add one `-e` line to the `docker run` invocation, alongside the existing `-e "HOST_CLAUDE_DIR=$CLAUDE_DIR"` (around current line 121):

```bash
    -e "SANDBOX_PROJECT_KEY=$PROJECT_KEY" \
```

- [ ] **Step 3: Verify** with the Verify command above; confirm the key is stable across runs.

- [ ] **Step 4: Re-install the wrapper** (it runs on the host, not in the image):

```sh
sudo install -m 755 /data/dev/claude-docker/claude-isolated /usr/local/bin/claude-isolated
```

- [ ] **Step 5: Commit**

```sh
git add claude-isolated
git commit -m "Pass a stable per-project key to the sandbox container"
```

---

### Task 3: Init + start the database in the entrypoint

**Goal:** Phase 2 of `entrypoint.sh` reads `/workspace/.claude-isolated.json` and, when it requests `database.type=postgres`, inits (first run) and starts a loopback-only Postgres cluster under `/state/pg/<key>/16`, creating the requested role+db — best-effort, warn-and-continue, never aborting the session.

**Files:**
- Modify: `entrypoint.sh` (add functions in phase 2; call them just before the default-command block at current lines ~221–227)

**Acceptance Criteria:**
- [ ] With a `.claude-isolated.json` requesting postgres, the log shows the cluster init (first run), `postgres listening on 127.0.0.1:<port>`, and role/db creation; `psql` connects.
- [ ] On a second run with the same project key, data persists: no re-init, role/db already present.
- [ ] With no `.claude-isolated.json` (or no `.database`), no Postgres action and no error.
- [ ] An unsupported `database.type` logs `unsupported database type '<x>'` and continues to launch Claude.
- [ ] A DB start failure logs a WARNING and still launches Claude (does not abort phase 2).
- [ ] The server binds `127.0.0.1` only.

**Verify:**
```sh
# Build first if Task 1 not yet built:
docker build -t claude-sandbox:latest /data/dev/claude-docker
# Prepare a throwaway workspace + state dir with a DB config:
mkdir -p /tmp/dbtest/ws /tmp/dbtest/state
printf '%s\n' '{"database":{"type":"postgres","name":"myapp","user":"myapp","password":"myapp","port":5432}}' \
  > /tmp/dbtest/ws/.claude-isolated.json
# Run the entrypoint non-interactively as the agent would, then prove psql connects:
docker run --rm \
  --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  -e SANDBOX_PROJECT_KEY=dbtest-000000000000 \
  -v /tmp/dbtest/ws:/workspace -w /workspace \
  -v /tmp/dbtest/state:/state \
  --entrypoint /usr/local/bin/entrypoint.sh \
  claude-sandbox:latest \
  bash -lc 'psql -h 127.0.0.1 -p 5432 -U myapp -d myapp -tAc "SELECT current_database(), current_user"'
```
Expected log lines include `initializing Postgres cluster`, `postgres listening on 127.0.0.1:5432`, `created role 'myapp'`, `created database 'myapp'`, and final query output `myapp|myapp`.
Re-running the same command should instead show no init and no "created" lines (data persisted in `/tmp/dbtest/state`).

**Steps:**

- [ ] **Step 1: Add the database functions** to `entrypoint.sh`. Insert this block in phase 2, after the `gh auth setup-git` block (after current line 219) and before the default-command block (current line 221):

```bash
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
```

- [ ] **Step 2: Build the image** so the entrypoint change is baked in:

```sh
docker build -t claude-sandbox:latest /data/dev/claude-docker
```

- [ ] **Step 3: Run the first-launch Verify** (the `docker run ... psql` command above). Expected: init + listening + created role/db log lines, final output `myapp|myapp`.

- [ ] **Step 4: Run it again** (same command) and confirm persistence: no `initializing` / `created` lines, query still returns `myapp|myapp`.

- [ ] **Step 5: Run the negative cases.**

```sh
# No config -> no DB action, Claude would still launch.
rm -f /tmp/dbtest/ws/.claude-isolated.json
docker run --rm -e SANDBOX_PROJECT_KEY=dbtest-000000000000 \
  -v /tmp/dbtest/ws:/workspace -w /workspace -v /tmp/dbtest/state:/state \
  --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  --entrypoint /usr/local/bin/entrypoint.sh claude-sandbox:latest \
  bash -lc 'echo NO-DB-OK'
# Unsupported type -> warning, still continues.
printf '%s\n' '{"database":{"type":"mysql"}}' > /tmp/dbtest/ws/.claude-isolated.json
docker run --rm -e SANDBOX_PROJECT_KEY=dbtest-000000000000 \
  -v /tmp/dbtest/ws:/workspace -w /workspace -v /tmp/dbtest/state:/state \
  --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  --entrypoint /usr/local/bin/entrypoint.sh claude-sandbox:latest \
  bash -lc 'echo CONTINUED-OK'
```
Expected: first prints `NO-DB-OK` with no DB log lines; second prints `unsupported database type 'mysql'` then `CONTINUED-OK`.

- [ ] **Step 6: Clean up the throwaway dirs and commit.**

```sh
rm -rf /tmp/dbtest
git add entrypoint.sh
git commit -m "Start an opt-in, loopback-only project database in phase 2"
```

---

### Task 4: Document the feature (generic only)

**Goal:** The README gains a "Project databases" section (mechanism, schema, defaults, persistence/concurrency, a copy-paste template with placeholders); `CLAUDE.md` gains a short note for sandbox editors. No project-specific content.

**Files:**
- Modify: `README.md` (add a `## Project databases` section + a Contents entry)
- Modify: `CLAUDE.md` (add a subsection under the architecture notes)

**Acceptance Criteria:**
- [ ] README documents the `.claude-isolated.json` `database` schema, all defaults, persistence under `/state`, the same-project concurrency caveat, and `localhost:<port>` access (not Docker).
- [ ] README includes a copy-paste JSON template using placeholders (`myapp`), and tells users to gitignore the file.
- [ ] README Contents list includes the new section anchor.
- [ ] `CLAUDE.md` explains how the Dockerfile / wrapper / entrypoint pieces interlock for this feature.
- [ ] No project-specific names anywhere in either doc.

**Verify:**
```sh
grep -n "Project databases" /data/dev/claude-docker/README.md
grep -n "claude-isolated.json" /data/dev/claude-docker/README.md /data/dev/claude-docker/CLAUDE.md
```
Expected: the section heading + Contents anchor in README, and schema mentions in both files.

**Steps:**

- [ ] **Step 1: Add the Contents anchor** to `README.md` — insert into the Contents list (around line 33, after the `Config isolation & persistence` entry):

```markdown
- [Project databases](#project-databases)
```

- [ ] **Step 2: Add the README section.** Place it after the `## Config isolation & persistence` section (pick the matching location in the rendered file). Use exactly this content:

````markdown
## Project databases

Some projects need a database (often run via `docker compose` outside the
sandbox). Docker isn't available inside the container — and Docker-in-Docker
would break the isolation model — but a database server is just a process on a
port, and **loopback traffic inside the container is unrestricted**, so a
sandbox-managed database needs no change to the egress firewall.

The image ships PostgreSQL 16 **dormant**. A project opts in with a gitignored
`/workspace/.claude-isolated.json`:

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

**Fields** (all optional; a `database` object must be present to trigger anything):

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

**Per-project recipe.** To tell a future agent session how to use this in a given
project, drop a note in *that project's* `CLAUDE.md`, e.g.:

> This project uses a sandbox-managed Postgres. Create `.claude-isolated.json`
> with `{"database":{"type":"postgres","name":"<db>","user":"<user>","password":"<pw>","port":<port>}}`
> matching `DATABASE_URL`, then run the project's migrate + seed scripts. Reach
> the DB with `psql -h localhost`.
````

- [ ] **Step 3: Add the `CLAUDE.md` note.** Append this subsection under the architecture section (e.g. after the "Config isolation" discussion), matching the file's existing voice:

```markdown
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
```

- [ ] **Step 4: Verify** with the Verify commands above.

- [ ] **Step 5: Commit**

```sh
git add README.md CLAUDE.md
git commit -m "Document the opt-in project database feature"
```

---

## Self-Review

**Spec coverage:**
- Config contract (`database`/`type`/`name`/`user`/`password`/`port`, defaults, dispatch) → Task 3 (`setup_database`/`start_postgres`) + Task 4 (docs).
- Image ships dormant server+client, build-arg, drop default cluster, PATH → Task 1.
- Wrapper supplies project key (sha256) → Task 2.
- Entrypoint best-effort init/start, loopback-only, per-project `/state` persistence, idempotent role/db, unsupported-type warn, never-abort → Task 3.
- Persistence & concurrency behavior → Task 3 (verify) + Task 4 (docs).
- Security analysis (loopback only, no privilege, no new host surface) → realized in Task 3 implementation; explained in Task 4 `CLAUDE.md`.
- Generic docs only, no project specifics → Task 4 (acceptance criteria enforce it).
- Out of scope (MySQL impl, lifecycle hooks, strict mode) → not built; engine-neutral `case` leaves the door open.
No gaps found.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". All code blocks are complete.

**Type/name consistency:** `setup_database` and `start_postgres` names, the `SANDBOX_PROJECT_KEY` env var, `/state/pg/<key>/16` path, and the `.claude-isolated.json` schema keys are used identically across Tasks 2–4 and the docs.
