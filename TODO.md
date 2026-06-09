# TODO

## Concurrent same-project sessions (decision deferred)

Running `claude-isolated` twice on the **same** project at once collides on
`$PWD`-keyed resources. (Different projects in parallel are fine.)

**Problems**
- **Ports (loud)** — same `cksum "$PWD"` host-port lane → `docker run -p` aborts
  "port is already allocated" (`claude-isolated:245-246`).
- **Postgres (dangerous, silent)** — shared on-host data dir `/state/pg/<key>/16`;
  separate PID/IPC namespaces defeat Postgres's stale-pid interlock → risk of two
  postmasters on one data dir = **corruption**.
- **Shared `/state` (minor)** — `.claude.json`, `history.jsonl` etc. last-writer-wins.

**Research done (empirically confirmed, arm64 / Docker 29.5.2)**
- `flock` mutexes across containers via the shared `/state` mount → clean owner-election.
- Pathname Unix socket reachable across network namespaces → DB sharing *possible* but
  transparent sharing needs socat shim + lock-holder + has an owner-exit-kills-borrower
  footgun (messy).

**Open decisions before implementing**
- [ ] Postgres: safe coexist via flock owner-election (recommended) vs transparent
      sharing (shim) vs per-session isolated data dir.
- [ ] Port override knob: `--no-ports` flag vs `CLAUDE_ISOLATED_DISABLE_PORTS=1` env vs both
      (plan is auto-detect-and-skip collisions either way).
- [ ] Shared `/state`: fix, or just document as a known limitation.
- [ ] Correct the wrapper header "no shared state" claim (`claude-isolated:3-4`) — only
      true across projects, not within one.

Full notes: memory `concurrent-same-project-sessions.md`.
