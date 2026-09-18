# swe2-dispatch

A Claude Code plugin that lets a Claude session hand a bounded implementation task to an **external SWE-2 agent** — Cognition's `devin` CLI — and collect a compact, verifiable result.

The dispatching session keeps ownership of integration, review, and git. The SWE-2 worker edits files inside one task-owned worktree and nothing else.

## Requirements

- **macOS.** Confinement uses `sandbox-exec` (seatbelt). On other platforms the script refuses to dispatch rather than running unconfined.
- **The `devin` CLI**, authenticated to an account with the SWE-2 model family. Set `DEVIN_BIN` if it is not at `~/.local/bin/devin`.
- `git` and `jq`.

Run the preflight to check all of it at once — it starts no agent and spends nothing:

```
"${CLAUDE_PLUGIN_ROOT}/bin/swe2-doctor.sh"
```

## Use

```
/swe2 fix the pagination bug in the orders list and add a regression test
```

Or drive it through the `swe2-runner` subagent, or call the script directly:

```
bin/swe2-dispatch.sh --workspace <linked worktree> --brief <task file> --out <run dir>
```

## What it enforces

Confinement is structural, not advisory. The script refuses to dispatch unless `--workspace` is the **root of a linked git worktree** — a primary or shared checkout is rejected, because a linked worktree has a `.git` *file* while a primary checkout has a `.git` *directory*.

The run is then wrapped in a generated seatbelt profile permitting writes only in the worktree, the run directory, that worktree's own git dir, and the agent's own state directories. Everything else is read-only.

A deliberate consequence: the *shared* git common directory is **not** writable, so `git add` and `git commit` fail at the OS level while `git status`, `diff`, and `log` still work. **The worker cannot stage or commit even if it tries.** The dispatching session owns the index.

`--mode dangerous` is always refused.

## What it reports

`stdout` stays small so the transcript never floods the calling session's context:

```
=== swe2 run 20260917-204503-11517 ===
status:     0
model:      swe-2-max (mode: smart, sandbox: on)
workspace:  /path/to/worktree  [branch: task/demo]
session_id: trite-scaffold   (resume: --resume trite-scaffold)
--- metrics ---      prompt/completion/cached tokens
--- tool calls ---   1 read, 1 edit, 1 exec
--- files touched --- m.py
--- diffstat ---     m.py | 2 +-
--- agent result (self-reported, VERIFY IT) ---
status: done
files: m.py
verified: python3 -c "import m; print(m.div(10,2))" → printed 5.0 (exit 0)
```

Full artifacts land in `--out`: `export.json` (the complete trace — ~100KB even for trivial runs, query it with `jq`, never read it whole), `actions.txt`, `answer.txt`, `brief.sent.md`, `sandbox.sb`, and the diffs.

## Briefs are composed for you

Your `--brief` file holds **only the task**. The script prepends standing constraints (stay in the worktree, do not commit, no unrelated refactors, never weaken a test, report honestly rather than plausibly) and appends a required `RESULT` block giving status, files, the verification command and its real outcome, and notes. `--raw` opts out of both.

Write briefs that name the files that may change, the acceptance criteria, and — most importantly — **the exact command that proves success**, because SWE-2 will run it and report what actually happened.

## Known limitations

These are measured, not hypothetical.

- **The worktree must already have its toolchain installed.** In non-interactive mode `devin` rejects any command its classifier wants confirmation for, which includes package installs. Observed twice: the agent made correct edits, then could not run `pytest` because it was absent and was refused when it tried to bootstrap it. Install dependencies before dispatching.
- **`--mode accept-edits` cannot run shell commands**, so the agent cannot verify its own work and dies on the first compound command. `smart` is the default for this reason.
- **The seatbelt blocks writes, not network.** A dispatch near credentials is not bounded by this.
- **`--allow-write <dir>`** grants extra writable subpaths for toolchain caches. Grant caches, never source trees.
- The `RESULT` block is self-reported. Always verify the diff yourself.

## Options

| Flag | Meaning |
|---|---|
| `--workspace <dir>` | Root of a linked git worktree. Required. |
| `--brief <file>` | The task. Required. |
| `--model <name>` | Default `swe-2-max`. |
| `--mode <mode>` | `smart` (default), `accept-edits`, `auto`. `dangerous` refused. |
| `--out <dir>` | Artifact directory. Defaults under `$TMPDIR`. |
| `--resume <id>` | Continue a prior session instead of starting cold. Much cheaper — context is cached. |
| `--allow-write <dir>` | Extra writable subpath. Repeatable. |
| `--scratch` | Permit a non-git directory, only under the temp root. |
| `--raw` | Send the brief unwrapped. |
| `--no-sandbox` | Dispatch unconfined. Avoid. |
