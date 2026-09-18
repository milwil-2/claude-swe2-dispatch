#!/usr/bin/env bash
# Dispatch a bounded task to a SWE-2 agent (Cognition `devin` CLI) and collect
# a compact result. Designed to be called by a Claude Code session: stdout stays
# small so the full agent transcript never lands in the lead's context.
#
#   swe2-dispatch.sh --workspace <dir> --brief <file> [--model swe-2-max]
#                    [--mode smart|accept-edits|auto] [--out <dir>] [--resume <id>]
#                    [--scratch] [--no-sandbox] [--raw] [--allow-write <dir>]...
#
# --allow-write grants one extra writable subpath (repeatable). Needed when the
# repo's verifier writes outside the worktree -- e.g. a package manager cache.
# Grant caches, never source trees.
#
# CONFINEMENT (enforced, not advisory):
#   * --workspace must be the ROOT of a *linked* git worktree. The primary or
#     shared checkout is refused: a linked worktree has a `.git` file, the
#     primary checkout has a `.git` directory.
#   * The run is wrapped in a macOS seatbelt profile that permits writes only in
#     the workspace, the run directory, and the worktree's git directory.
#     --no-sandbox must be given explicitly to disable it.
#   * --scratch permits a non-git directory, but only under the temp root.
#   * --mode dangerous is always refused.
#
# MODE defaults to `smart`. Under `accept-edits`, devin auto-approves edits and
# read-only tools only -- a compound shell command (or a test run) needs
# confirmation, which non-interactive mode rejects outright, so the agent cannot
# verify its own work. Verified 2026-09-17. The seatbelt profile, not the
# permission mode, is what bounds where the agent can write.
#
# Exit status is the agent's own exit status, or 2 for a usage/guard failure.

set -uo pipefail

DEVIN="${DEVIN_BIN:-$HOME/.local/bin/devin}"
MODEL="swe-2-max"
MODE="smart"   # see note at dispatch: accept-edits cannot run shell commands
WORKSPACE=""
BRIEF=""
OUT=""
RESUME=""
SCRATCH=0
SANDBOX=1
RAW=0
EXTRA_WRITES=()

die() { echo "swe2-dispatch: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)  WORKSPACE="$2"; shift 2 ;;
    --brief)      BRIEF="$2";     shift 2 ;;
    --model)      MODEL="$2";     shift 2 ;;
    --mode)       MODE="$2";      shift 2 ;;
    --out)        OUT="$2";       shift 2 ;;
    --resume)     RESUME="$2";    shift 2 ;;
    --scratch)    SCRATCH=1;      shift 1 ;;
    --no-sandbox) SANDBOX=0;      shift 1 ;;
    --raw)        RAW=1;          shift 1 ;;
    --allow-write) EXTRA_WRITES+=("$2"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "$DEVIN"     ]] || die "devin CLI not found at $DEVIN"
[[ -n "$WORKSPACE" ]] || die "--workspace is required"
[[ -d "$WORKSPACE" ]] || die "--workspace must be an existing directory"
[[ -f "$BRIEF"     ]] || die "--brief must be an existing file"
[[ "$MODE" == "dangerous" ]] && die "--mode dangerous is not permitted"

WORKSPACE="$(cd "$WORKSPACE" && pwd -P)" || die "cannot resolve --workspace"

# ---- Confinement guard -------------------------------------------------------
TOPLEVEL="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null)"

if [[ -z "$TOPLEVEL" ]]; then
  # Not a git repo at all.
  if [[ "$SCRATCH" != "1" ]]; then
    die "$WORKSPACE is not a git worktree. Dispatch is confined to a task-owned
              linked worktree. Use --scratch only for a throwaway directory under the temp root."
  fi
  TMPROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  case "$WORKSPACE/" in
    "$TMPROOT"/*|/private/tmp/*|/tmp/*) : ;;
    *) die "--scratch is limited to directories under the temp root; $WORKSPACE is not" ;;
  esac
  IS_GIT=0
else
  TOPLEVEL="$(cd "$TOPLEVEL" && pwd -P)"
  [[ "$TOPLEVEL" == "$WORKSPACE" ]] || \
    die "--workspace must be the worktree ROOT ($TOPLEVEL), not a subdirectory"
  if [[ -d "$TOPLEVEL/.git" ]]; then
    die "$TOPLEVEL is a primary/shared checkout (.git is a directory).
              Dispatch is confined to a task-owned linked worktree; create one with
              'git worktree add' and point --workspace at it."
  fi
  [[ -f "$TOPLEVEL/.git" ]] || die "$TOPLEVEL has no recognizable .git entry"
  IS_GIT=1
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUT="${OUT:-${TMPDIR:-/tmp}/swe2-runs/$RUN_ID}"
mkdir -p "$OUT" || exit 2

# Marker for mtime-based change detection. Diffing `git status --porcelain`
# before/after misses edits to files that were ALREADY dirty, which is the normal
# case on a resumed run -- verified broken 2026-09-17.
MARKER="$OUT/.start-marker"; touch "$MARKER"
sleep 1  # filesystem mtime granularity

# Record the pre-run tree state so we can report exactly what the agent touched.
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" rev-parse HEAD        > "$OUT/head.before"   2>/dev/null
  git -C "$WORKSPACE" status --porcelain    > "$OUT/status.before" 2>/dev/null
  git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD > "$OUT/branch"  2>/dev/null
fi

# ---- Brief composition -------------------------------------------------------
# SWE-2 starts with no context from the dispatching session, so every brief gets
# the same invariants and a machine-readable output contract. --raw skips this.
SENT_BRIEF="$BRIEF"
if [[ "$RAW" != "1" ]]; then
  SENT_BRIEF="$OUT/brief.sent.md"
  {
    echo "You are working in a dedicated git worktree at: $WORKSPACE"
    echo "That directory is your current working directory and the ONLY place you may write."
    echo
    echo "## Standing constraints"
    echo
    echo "- Write only inside the worktree. Writes elsewhere are blocked by the OS, not just by policy."
    echo "- Do NOT stage, commit, push, branch, or amend. \`git add\` will fail by design; that is expected, not a problem to solve. Leave your work as uncommitted changes."
    echo "- Read-only git (\`git status\`, \`git diff\`, \`git log\`) is available and encouraged."
    echo "- Change only what the task requires. No unrelated refactors, reformatting, or added comments on code you did not touch."
    echo "- Never weaken, skip, or delete a test to make things pass, and never hard-code for a specific test input. If the test or the task looks wrong, say so instead."
    echo "- If you cannot complete something, stop and report it. A partial, honestly-reported result is correct; a plausible-looking guess is not."
    echo
    echo "## Task"
    echo
    cat "$BRIEF"
    echo
    echo "## Required final message"
    echo
    echo "End your final message with exactly this block, and nothing after it:"
    echo
    echo "RESULT"
    echo "status: done | partial | blocked"
    echo "files: <comma-separated paths you changed, relative to the worktree, or none>"
    echo "verified: <the exact command you ran to check your work and its real outcome, or 'not run'>"
    echo "notes: <one line: anything skipped, uncertain, or that the reviewer must know>"
  } > "$SENT_BRIEF"
fi

DEVIN_ARGS=(-p
  --prompt-file "$SENT_BRIEF"
  --model "$MODEL"
  --permission-mode "$MODE"
  --respect-workspace-trust false
  --export "$OUT/export.json")
[[ -n "$RESUME" ]] && DEVIN_ARGS+=(--resume "$RESUME")

# NOTE: devin's own --sandbox is NOT used. It forces the autonomous permission
# mode, which in non-interactive (-p) mode rejects every edit that would need
# confirmation -- verified 2026-09-17: the agent could not apply even an
# in-scope edit. We impose the boundary ourselves with macOS seatbelt instead,
# which does not depend on devin honoring anything.
PRIVTMP="$OUT/tmp"; mkdir -p "$PRIVTMP"
SANDBOX_CMD=()
if [[ "$SANDBOX" == "1" ]]; then
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    die "sandbox-exec not available; re-run with --no-sandbox to dispatch unconfined"
  fi
  # A linked worktree's real git directory lives under the MAIN repo, outside
  # the workspace; git needs to write there (index.lock, HEAD, ...).
  # Only this worktree's own git dir is writable -- NOT the shared common dir.
  # Verified: read-only git (status/diff/log) works, while `git add` fails at the
  # OS level, so the worker structurally cannot stage or commit. The lead owns
  # the index.
  GITDIR=""
  if [[ "$IS_GIT" == "1" ]]; then
    GITDIR="$(cd "$(git -C "$WORKSPACE" rev-parse --git-dir)" && pwd -P 2>/dev/null)"
  fi
  {
    echo '(version 1)'
    echo '(allow default)'
    echo '(deny file-write*)'
    echo '(allow file-write*'
    echo "  (subpath \"$WORKSPACE\")"
    echo "  (subpath \"$OUT\")"
    [[ -n "$GITDIR" ]] && echo "  (subpath \"$GITDIR\")"
    echo "  (subpath \"$HOME/.local/share/devin\")"
    echo "  (subpath \"$HOME/.config/devin\")"
    echo "  (subpath \"$HOME/.cache\")"
    # Toolchain caches a repo's verifier needs, granted explicitly per dispatch.
    for extra in "${EXTRA_WRITES[@]+"${EXTRA_WRITES[@]}"}"; do
      [[ -e "$extra" ]] || continue
      echo "  (subpath \"$(cd "$extra" 2>/dev/null && pwd -P || echo "$extra")\")"
    done
    echo '  (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr")'
    echo '  (regex #"^/dev/tty") (regex #"^/private/var/folders/"))'
  } > "$OUT/sandbox.sb"
  SANDBOX_CMD=(sandbox-exec -f "$OUT/sandbox.sb")
fi

cd "$WORKSPACE" || exit 2
TMPDIR="$PRIVTMP" "${SANDBOX_CMD[@]}" "$DEVIN" "${DEVIN_ARGS[@]}" \
  > "$OUT/answer.txt" 2> "$OUT/stderr.txt"
STATUS=$?

# ---- Reduce the transcript to something a supervising session can afford ----
SESSION_ID=""
if [[ -s "$OUT/export.json" ]] && command -v jq >/dev/null 2>&1; then
  SESSION_ID="$(jq -r '.session_id // ""' "$OUT/export.json")"
  jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls | length) > 0)
         | .tool_calls[] | .function_name // .function.name // .name // "tool"' \
     "$OUT/export.json" 2>/dev/null | sort | uniq -c | sort -rn > "$OUT/tools.txt"
  jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls | length) > 0)
         | .tool_calls[] | "\(.function_name // "tool")\t\(.arguments | tostring | .[0:200])"' \
     "$OUT/export.json" 2>/dev/null > "$OUT/actions.txt"
  jq -r '.final_metrics // {}' "$OUT/export.json" > "$OUT/metrics.json" 2>/dev/null
fi

ESCAPED=""
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" status --porcelain > "$OUT/status.after"  2>/dev/null
  git -C "$WORKSPACE" diff               > "$OUT/unstaged.diff" 2>/dev/null
  git -C "$WORKSPACE" diff --cached      > "$OUT/staged.diff"   2>/dev/null
  # Files whose contents changed during THIS run (works on already-dirty files).
  find "$WORKSPACE" -type f -newer "$MARKER" -not -path "*/.git/*" 2>/dev/null \
    | sed "s|^$WORKSPACE/||" \
    | { command -v git >/dev/null && git -C "$WORKSPACE" check-ignore -v --stdin --non-matching 2>/dev/null \
        | awk -F'\t' '$1 ~ /^::/ {print $2}' || cat; } \
    | sort -u > "$OUT/changed.txt" 2>/dev/null
  # Did the agent try to write outside the workspace? Report any such attempt.
  if [[ -s "$OUT/actions.txt" ]]; then
    grep -oE '"file_path":"[^"]+"' "$OUT/actions.txt" 2>/dev/null \
      | sed 's/"file_path":"//; s/"$//' | sort -u \
      | grep -v "^$WORKSPACE/" > "$OUT/outside.txt" 2>/dev/null
    [[ -s "$OUT/outside.txt" ]] && ESCAPED=1
  fi
fi

# ---- Compact report on stdout: this is what the calling session reads ----
echo "=== swe2 run $RUN_ID ==="
echo "status:     $STATUS"
echo "model:      $MODEL (mode: $MODE, sandbox: $([[ $SANDBOX == 1 ]] && echo on || echo OFF))"
echo "workspace:  $WORKSPACE$([[ -s "$OUT/branch" ]] && echo "  [branch: $(cat "$OUT/branch")]")"
[[ -n "$SESSION_ID" ]] && echo "session_id: $SESSION_ID   (resume: --resume $SESSION_ID)"
echo "artifacts:  $OUT"
if [[ -s "$OUT/metrics.json" ]]; then echo "--- metrics ---"; cat "$OUT/metrics.json"; fi
if [[ -s "$OUT/tools.txt"    ]]; then echo "--- tool calls ---"; cat "$OUT/tools.txt"; fi
if [[ "$IS_GIT" == "1" ]]; then
  echo "--- files touched ---"
  if [[ -s "$OUT/changed.txt" ]]; then cat "$OUT/changed.txt"; else echo "(none)"; fi
  echo "--- diffstat ---"
  git -C "$WORKSPACE" diff --stat 2>/dev/null | tail -20
fi
if [[ -n "$ESCAPED" ]]; then
  echo "--- !! PATHS TOUCHED OUTSIDE WORKSPACE !! ---"
  cat "$OUT/outside.txt"
fi
if [[ -s "$OUT/stderr.txt" ]]; then echo "--- stderr (tail) ---"; tail -20 "$OUT/stderr.txt"; fi
# Surface the structured contract block first; fall back to the raw answer.
if grep -q '^RESULT[[:space:]]*$' "$OUT/answer.txt" 2>/dev/null; then
  echo "--- agent result (self-reported, VERIFY IT) ---"
  sed -n '/^RESULT[[:space:]]*$/,$p' "$OUT/answer.txt" | tail -n +2
  echo "--- full answer: $OUT/answer.txt ---"
else
  echo "--- agent answer (no RESULT block returned) ---"
  cat "$OUT/answer.txt"
fi

exit $STATUS
