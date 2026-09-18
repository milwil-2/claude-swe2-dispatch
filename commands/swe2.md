---
description: Dispatch a bounded task to a SWE-2 agent inside a task-owned git worktree, then verify what it produced.
argument-hint: <what you want SWE-2 to do>
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/bin/swe2-dispatch.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/bin/swe2-doctor.sh:*)", "Read", "Glob", "Grep"]
---

Dispatch this task to a SWE-2 agent: $ARGUMENTS

Do it in this order.

1. **Pick the worktree.** Dispatch is refused anywhere but the root of a *linked* git worktree, so identify one the current task owns. If there isn't one, create it (`git worktree add`) from a freshly fetched base and say which branch you used. Never dispatch into the primary checkout — the script will refuse it anyway.

2. **Check the toolchain is already installed in that worktree.** SWE-2 cannot install packages: in non-interactive mode `devin` rejects any command needing confirmation, and this plugin refuses `--mode dangerous`. If dependencies are missing (no `node_modules`, no test runner), install them yourself *before* dispatching, or SWE-2 will make changes it cannot verify.

3. **Write the brief to a file.** Include only the task itself — the script prepends the standing constraints and appends the required `RESULT` block. Name the files SWE-2 may change, the acceptance criteria, and above all **the exact command that proves success**, since it will run that command and report the real outcome.

4. **Dispatch:**

```
"${CLAUDE_PLUGIN_ROOT}/bin/swe2-dispatch.sh" \
  --workspace <absolute worktree> --brief <absolute brief file> --out <absolute run dir>
```

   Add `--allow-write <dir>` for any cache the repo's verifier writes outside the worktree. Never pass `--no-sandbox`, `--raw`, or `--mode dangerous`. Runs take minutes — raise the Bash `timeout`, or use `run_in_background` and poll the run directory.

5. **Verify independently.** The `RESULT` block is self-reported. Read the actual `git diff`, run the acceptance command yourself, and check for collateral: files outside the stated scope, new untracked artifacts, weakened or deleted tests. Never read `export.json` into context — it is ~100KB; query it with `jq`.

6. **Report**: what changed with `path:line` references, the command you ran and its real output, anything beyond or short of the brief, and the `session_id` so the run can be resumed with `--resume`.

You own integration, review, and git. SWE-2 cannot stage or commit — that is enforced by the sandbox, not by instruction.
