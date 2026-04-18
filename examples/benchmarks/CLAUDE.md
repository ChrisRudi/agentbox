# CLAUDE.md — benchmarks demo project

## What this project is

This is the agentbox build-flow demo. It exists so you (the agent) can
demonstrate the full Task-Runner round-trip end-to-end: you write a
task file, the host-side runner validates and executes `build.ps1`,
and the result lands back in `_tasks/status_build.json`.

Don't edit `project.json` — it's read-only for you (per
`/workspace/SYSTEM_META_PROMPT.md`). The build command is already
wired: `powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1`.

## How to trigger a build (exact steps)

Write the task file as `.tmp` first, then rename — the runner only
picks up `.json` files, so the rename guarantees atomicity:

```bash
cat > /workspace/_tasks/build_001.tmp << 'EOF'
{
  "project": "benchmarks",
  "action": "build",
  "timestamp": "2026-04-18T14:30:00"
}
EOF

mv /workspace/_tasks/build_001.tmp /workspace/_tasks/build_001.json
```

Then poll `/workspace/_tasks/status_build.json` until `status` is
`done` or `failed`:

```bash
while [ ! -f /workspace/_tasks/status_build.json ] || \
      grep -q '"status": "running"' /workspace/_tasks/status_build.json; do
    sleep 1
done
cat /workspace/_tasks/status_build.json
```

On success, `bench-results.txt` in the project root will contain a
host-side bench block (disk + network numbers). On failure, the
status file includes an `error` field.

## Why this demo matters

- Shows the **build command doesn't execute in the sandbox** — it
  runs on the Windows host via `cmd.exe /c`. That's why
  `build.ps1` can measure real NTFS disk-write speed and host-side
  HTTPS download throughput.
- Shows the **exact-match whitelist**: if someone tampers with
  `build.command` in `project.json` (they can't, it's read-only, but
  hypothetically), the runner rejects it before execution.
- Shows that **the agent never touches PowerShell** — you only write
  a 3-line JSON file; everything else is plumbed.

## If the build fails

Read `_tasks/status_build.json` for the `error` field. Common causes:

- `_control/tools/bench.ps1` missing → user hasn't pulled a recent
  agentbox version. `build.ps1` falls back to a no-op "demo build
  completed" message in that case, so status should still be `done`.
- Whitelist mismatch → shouldn't happen in this demo; means someone
  changed `project.json:build.command` away from the canonical form.

## Session log

(Add notes here at the end of each session so the next agent knows
what was already tried.)
