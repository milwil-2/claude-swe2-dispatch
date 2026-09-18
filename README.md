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

Confinement is structural, not advisory. The script refuses to dispatch unless `--workspace` is the root of a **linked git worktree**, verified by requiring its git dir to be `<common-dir>/worktrees/<name>`. Checking only that `.git` is a *file* is not sufficient — a submodule's `.git` is also a file, pointing at a complete git directory that would then be writable and committable. Primary checkouts, submodules, and planted `.git` files are all refused.

Git environment variables (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, …) are unset before any `git` call, because `rev-parse` honors them and an inherited value would make the guard inspect a different repository than `--workspace`.

The run is then wrapped in a generated seatbelt profile permitting **writes** only in: the worktree, the run directory, and the agent's `devin` state directories. Writes anywhere else — including `$TMPDIR`, `~/.cache`, `$HOME`, and **the worktree's own git directory** — are denied by the OS. **Reads are not restricted**, and neither is network access.

No writable git directory is granted at all. Verified: `git status`, `git diff`, and `git log` still work read-only without one, while `git add`, `git commit`, and `git update-index --assume-unchanged` all fail on `index.lock`. That last one matters — it would otherwise let an agent hide a sabotaged tracked file from both this report *and* the `git diff` you are told to check. **The worker cannot stage, commit, or touch the index.**

`--out` must be outside the worktree and outside every `--allow-write` path, because everything the report trusts as a baseline is kept in a private control directory the agent cannot reach.

Paths interpolated into that profile are rejected if they contain characters that could terminate an S-expression (`"`, `)`, `(`, `\`, `;`, newline), so a crafted `--allow-write` or workspace path cannot widen the grant.

`--mode` is an allowlist: `smart`, `accept-edits`, `auto`. Anything else, including `dangerous` in any casing, is refused.

Change detection is computed outside the sandbox from state the agent cannot forge:

- **ctime, not mtime.** `touch -t` rewrites mtime and atime but not ctime, and ctime cannot be moved backwards without root — so backdating a planted or edited file does not hide it. Comparison is against a reference file in the control directory.
- **A path-set delta** against a pre-run inventory, which catches deletions (reported as `[DELETED]`).
- **`.gitignore` is never used to filter this list.** A self-ignoring `.gitignore` was a working hiding primitive; ignored files are annotated `[gitignored]`, never removed.

If the run produced no usable trace (no `export.json`, or `jq` missing), the report says `escape check: NOT PERFORMED` with the reason. Silence never reads as a clean result.

## Orchestration safety

- **One dispatch per worktree**, enforced with an atomic lock. Two concurrent agents in one tree would interleave edits and make every "what changed" answer meaningless. A lock whose owning process is gone is taken over automatically.
- **Every run is time-bounded** (`--timeout`, default 30 minutes). A run that hits the deadline is killed and the report says `!! TIMED OUT ... any work below is PARTIAL !!` rather than presenting a truncated result as finished.
- **A worktree that was already dirty is disclosed** at the top of the report, with the count of pre-existing entries, so "files touched" is never read as "everything that is uncommitted here".

## Tests

```
tests/run-tests.sh            # all
tests/run-tests.sh sandbox    # just the cases matching 'sandbox'
```

46 cases, no network and no cost — they drive the script with stub agents via `DEVIN_BIN`. Every case corresponds to a defect an independent reviewer found and reproduced, including the hostile-agent ones: backdating planted files, a self-ignoring `.gitignore`, `git update-index --assume-unchanged`, `GIT_DIR` guard bypass, profile injection, and upward traversal in the trace.

Run them before changing `bin/swe2-dispatch.sh`. Two rounds of review fixes were defeated by the next reviewer; these exist so that cannot happen quietly again.

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
| `--timeout <s>` | Wall-clock bound on the agent, default 1800. SIGTERM at the deadline, SIGKILL five seconds later. |
| `--no-sandbox` | Dispatch unconfined. Avoid. |
