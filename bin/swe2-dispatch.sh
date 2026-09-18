#!/usr/bin/env bash
# Dispatch a bounded task to a SWE-2 agent (Cognition `devin` CLI) and collect
# a compact result. Designed to be called by a Claude Code session: stdout stays
# small so the full agent transcript never lands in the caller's context.
#
#   swe2-dispatch.sh --workspace <dir> --brief <file> [--model swe-2-max]
#                    [--mode smart|accept-edits|auto] [--out <dir>] [--resume <id>]
#                    [--scratch] [--no-sandbox] [--raw] [--allow-write <dir>]...
#                    [--timeout <seconds>]
#
# CONFINEMENT (enforced, not advisory):
#   * --workspace must be the root of a *linked git worktree*: its git dir must
#     be <common-dir>/worktrees/<name>. A primary checkout, a submodule, and a
#     planted `.git` file are all refused -- merely having a `.git` FILE is not
#     sufficient, because a submodule's `.git` is also a file pointing at a
#     complete git dir that would then be writable.
#   * The run is wrapped in a macOS seatbelt profile permitting writes only in
#     the workspace, the run directory, and that worktree's own git dir. The
#     shared git common dir stays read-only, so the agent cannot stage or commit.
#   * Paths interpolated into that profile are rejected if they contain
#     characters that could terminate an S-expression.
#   * --scratch permits a non-git directory, but only under the temp root.
#   * --mode is an allowlist; `dangerous` and anything unrecognized is refused.
#
# MODE defaults to `smart`. Under `accept-edits`, devin auto-approves edits and
# read-only tools only -- a compound shell command or a test run needs
# confirmation, which non-interactive mode rejects outright, so the agent cannot
# verify its own work.
#
# Exit status is the agent's own exit status, or 2 for a usage/guard failure.

set -uo pipefail

# git's rev-parse honors these, so an inherited value would make the guard
# inspect a repository that has nothing to do with --workspace. They are also
# routinely set inside git hooks, so this is not only a hostile-caller concern.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES 2>/dev/null

DEVIN="${DEVIN_BIN:-$HOME/.local/bin/devin}"
MODEL="swe-2-max"
MODE="smart"
WORKSPACE=""
BRIEF=""
OUT=""
RESUME=""
SCRATCH=0
SANDBOX=1
RAW=0
TIMEOUT=1800
EXTRA_WRITES=()

die() { echo "swe2-dispatch: $*" >&2; exit 2; }
need_val() { [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"; }

# Reject anything that could break out of a (subpath "...") S-expression.
safe_for_profile() {
  case "$1" in
    *'"'*|*'\'*|*'('*|*')'*|*';'*) return 1 ;;
    *[$'\n\t\r']*) return 1 ;;
  esac
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)   need_val "$@"; WORKSPACE="$2"; shift 2 ;;
    --brief)       need_val "$@"; BRIEF="$2";     shift 2 ;;
    --model)       need_val "$@"; MODEL="$2";     shift 2 ;;
    --mode)        need_val "$@"; MODE="$2";      shift 2 ;;
    --out)         need_val "$@"; OUT="$2";       shift 2 ;;
    --resume)      need_val "$@"; RESUME="$2";    shift 2 ;;
    --allow-write) need_val "$@"; EXTRA_WRITES+=("$2"); shift 2 ;;
    --scratch)     SCRATCH=1; shift 1 ;;
    --no-sandbox)  SANDBOX=0; shift 1 ;;
    --raw)         RAW=1;     shift 1 ;;
    --timeout)     need_val "$@"; TIMEOUT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "$DEVIN"     ]] || die "devin CLI not found at $DEVIN"
[[ -n "$WORKSPACE" ]] || die "--workspace is required"
[[ -d "$WORKSPACE" ]] || die "--workspace must be an existing directory"
[[ -f "$BRIEF"     ]] || die "--brief must be an existing file"
case "$MODE" in
  smart|accept-edits|auto) : ;;
  *) die "--mode must be one of: smart, accept-edits, auto (got '$MODE')" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a whole number of seconds (got '$TIMEOUT')" ;;
esac
[[ "$TIMEOUT" -gt 0 ]] || die "--timeout must be greater than zero"

WORKSPACE="$(cd "$WORKSPACE" && pwd -P)" || die "cannot resolve --workspace"
safe_for_profile "$WORKSPACE" || die "--workspace path contains characters that cannot be sandboxed safely"

# ---- Confinement guard -------------------------------------------------------
GITDIR=""
TOPLEVEL="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null)"

if [[ -z "$TOPLEVEL" ]]; then
  [[ "$SCRATCH" == "1" ]] || die "$WORKSPACE is not a git worktree. Dispatch is confined to a
              task-owned LINKED worktree. Use --scratch only for a throwaway directory
              under the temp root."
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

  GITDIR="$(git -C "$WORKSPACE" rev-parse --absolute-git-dir 2>/dev/null)"
  COMMON="$(git -C "$WORKSPACE" rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$GITDIR" && -n "$COMMON" ]] || die "cannot resolve the git directory for $WORKSPACE"
  # --git-common-dir may be relative to the workspace.
  case "$COMMON" in /*) : ;; *) COMMON="$WORKSPACE/$COMMON" ;; esac
  GITDIR="$(cd "$GITDIR" && pwd -P)" || die "cannot resolve git dir"
  COMMON="$(cd "$COMMON" && pwd -P)" || die "cannot resolve git common dir"

  # A linked worktree's git dir is <common>/worktrees/<name>. This rejects the
  # primary checkout (gitdir == common), a submodule (gitdir is
  # <super>/.git/modules/<name>, and IS its own complete git dir), and a planted
  # `.git` file pointing at a shared git dir -- each of which would otherwise
  # make a writable, commit-capable git directory.
  case "$GITDIR" in
    "$COMMON"/worktrees/*) : ;;
    *) die "$WORKSPACE is not a linked git worktree.
              git dir:    $GITDIR
              common dir: $COMMON
              A linked worktree's git dir must be <common>/worktrees/<name>. Primary
              checkouts, submodules, and planted .git files are refused because their
              git directory would be writable and could be committed to. Create one
              with 'git worktree add'." ;;
  esac
  safe_for_profile "$GITDIR" || die "git dir path contains characters that cannot be sandboxed safely"
  IS_GIT=1
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUT="${OUT:-${TMPDIR:-/tmp}/swe2-runs/$RUN_ID}"
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd -P)" || exit 2
safe_for_profile "$OUT" || die "--out path contains characters that cannot be sandboxed safely"

# Stale artifacts from a reused --out must never be reported as this run's.
rm -f "$OUT/export.json" "$OUT/answer.txt" "$OUT/stderr.txt" "$OUT/tools.txt" \
      "$OUT/actions.txt" "$OUT/metrics.json" "$OUT/outside.txt" "$OUT/changed.txt" \
      "$OUT/status.before" "$OUT/status.after" "$OUT/branch" "$OUT/head.before" \
      "$OUT/unstaged.diff" "$OUT/staged.diff" "$OUT/changed.raw" "$OUT/brief.sent.md" \
      "$OUT/sandbox.sb" 2>/dev/null

# $OUT is granted to the agent, so nothing the report trusts may live in it, and
# it must not sit inside the workspace (which is also agent-writable).
case "$OUT/" in
  "$WORKSPACE"/*) die "--out must not be inside the workspace ($OUT); the agent can write there" ;;
esac
for extra in ${EXTRA_WRITES[@]+"${EXTRA_WRITES[@]}"}; do
  ex="$(cd "$extra" 2>/dev/null && pwd -P)" || continue
  case "$OUT/" in "$ex"/*) die "--out must not be inside an --allow-write path ($ex)" ;; esac
done

# Control directory: holds every baseline the report trusts. It lives outside
# $OUT, outside the workspace, and outside every granted path, so the agent
# cannot reach it at all.
CTL="${TMPDIR:-/tmp}/.swe2-ctl-$RUN_ID"
case "$CTL/" in "$WORKSPACE"/*|"$OUT"/*) CTL="/tmp/.swe2-ctl-$RUN_ID" ;; esac
mkdir -p "$CTL" || exit 2
chmod 700 "$CTL" 2>/dev/null

# One dispatch per worktree. Two concurrent agents in one tree would interleave
# edits and make every "what changed" answer meaningless. mkdir is atomic.
LOCK="${TMPDIR:-/tmp}/.swe2-lock-$(printf '%s' "$WORKSPACE" | cksum | tr -d ' /')"
if ! mkdir "$LOCK" 2>/dev/null; then
  OWNER="$(cat "$LOCK/pid" 2>/dev/null)"
  if [[ -n "$OWNER" ]] && kill -0 "$OWNER" 2>/dev/null; then
    rm -rf "$CTL"
    die "another dispatch (pid $OWNER) is already running in this worktree.
              Wait for it, or dispatch into a different worktree."
  fi
  # Stale lock from a killed run: take it over.
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { rm -rf "$CTL"; die "cannot acquire the dispatch lock at $LOCK"; }
fi
printf '%s' "$$" > "$LOCK/pid"
trap 'rm -rf "$CTL" "$LOCK"' EXIT INT TERM

# Inventory the tree BEFORE the run. Paths only -- cheap even on a large repo.
find "$WORKSPACE" -type f -not -path "*/.git/*" -print 2>/dev/null | sort > "$CTL/files.before"
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" rev-parse HEAD              > "$CTL/head.before"   2>/dev/null
  git -C "$WORKSPACE" status --porcelain          > "$CTL/status.before" 2>/dev/null
  git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD > "$OUT/branch"        2>/dev/null
fi
sleep 1  # timestamp granularity
# Reference file for ctime comparison. It lives in $CTL, which the agent cannot
# reach, and -newercm compares each file's CTIME against this marker's mtime --
# ctime cannot be moved backwards by `touch`, so backdating a planted or edited
# file does not hide it.
MARKER="$CTL/start-marker"; touch "$MARKER"

# ---- Brief composition -------------------------------------------------------
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
# mode, which in non-interactive (-p) mode rejects every edit needing
# confirmation -- the agent cannot apply even an in-scope edit. We impose the
# boundary ourselves with macOS seatbelt instead.
PRIVTMP="$OUT/tmp"; mkdir -p "$PRIVTMP"
SANDBOX_CMD=()
if [[ "$SANDBOX" == "1" ]]; then
  command -v sandbox-exec >/dev/null 2>&1 || \
    die "sandbox-exec not available; re-run with --no-sandbox to dispatch unconfined"
  DEVIN_STATE="$HOME/.local/share/devin"; DEVIN_CFG="$HOME/.config/devin"
  safe_for_profile "$DEVIN_STATE" && safe_for_profile "$DEVIN_CFG" || \
    die "home directory path contains characters that cannot be sandboxed safely"
  {
    echo '(version 1)'
    echo '(allow default)'
    echo '(deny file-write*)'
    echo '(allow file-write*'
    echo "  (subpath \"$WORKSPACE\")"
    echo "  (subpath \"$OUT\")"
    # The worktree's git dir is deliberately NOT granted. Verified: `git status`,
    # `git diff` and `git log` still work read-only without it, while
    # `git update-index --assume-unchanged` -- which would hide a sabotaged
    # tracked file from both the report AND `git diff` -- fails on index.lock.
    echo "  (subpath \"$DEVIN_STATE\")"
    echo "  (subpath \"$DEVIN_CFG\")"
    for extra in ${EXTRA_WRITES[@]+"${EXTRA_WRITES[@]}"}; do
      safe_for_profile "$extra" || \
        die "--allow-write path contains characters that cannot be sandboxed safely: $extra"
      [[ -e "$extra" ]] || die "--allow-write path does not exist: $extra"
      resolved="$(cd "$extra" 2>/dev/null && pwd -P)" || \
        die "--allow-write must be a directory: $extra"
      safe_for_profile "$resolved" || \
        die "--allow-write path contains characters that cannot be sandboxed safely: $extra"
      echo "  (subpath \"$resolved\")"
    done
    echo '  (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr")'
    echo '  (regex #"^/dev/tty"))'
  } > "$OUT/sandbox.sb"
  SANDBOX_CMD=(sandbox-exec -f "$OUT/sandbox.sb")
fi

cd "$WORKSPACE" || exit 2
# A runaway agent otherwise runs until the caller notices. The watchdog gives it
# SIGTERM at the deadline and SIGKILL five seconds later.
STARTED_AT="$(date '+%s')"
TMPDIR="$PRIVTMP" ${SANDBOX_CMD[@]+"${SANDBOX_CMD[@]}"} "$DEVIN" "${DEVIN_ARGS[@]}" \
  > "$OUT/answer.txt" 2> "$OUT/stderr.txt" &
AGENT_PID=$!
( sleep "$TIMEOUT"
  kill -TERM "$AGENT_PID" 2>/dev/null && { sleep 5; kill -KILL "$AGENT_PID" 2>/dev/null; }
) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$AGENT_PID"; STATUS=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
ELAPSED=$(( $(date '+%s') - STARTED_AT ))
TIMED_OUT=""
[[ "$STATUS" -gt 128 && "$ELAPSED" -ge "$TIMEOUT" ]] && TIMED_OUT=1

# ---- Reduce the transcript to something a supervising session can afford ----
SESSION_ID=""; HAVE_TRACE=0; TRACE_WHY="no export.json was written"
if [[ -s "$OUT/export.json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    HAVE_TRACE=1
    SESSION_ID="$(jq -r '.session_id // ""' "$OUT/export.json")"
    jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls | length) > 0)
           | .tool_calls[] | .function_name // .function.name // .name // "tool"' \
       "$OUT/export.json" 2>/dev/null | sort | uniq -c | sort -rn > "$OUT/tools.txt"
    jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls | length) > 0)
           | .tool_calls[] | "\(.function_name // "tool")\t\(.arguments | tostring)"' \
       "$OUT/export.json" 2>/dev/null > "$OUT/actions.txt"
    jq -r '.final_metrics // {}' "$OUT/export.json" > "$OUT/metrics.json" 2>/dev/null
  else
    TRACE_WHY="jq is not installed"
  fi
fi
if [[ "$HAVE_TRACE" == "1" && ! -s "$OUT/actions.txt" ]]; then
  TRACE_WHY="the trace recorded no tool calls with arguments"
fi

# ---- What changed -----------------------------------------------------------
# Ground truth is computed here, outside the sandbox, from state the agent
# cannot forge:
#   * ctime, not mtime. `touch -t` rewrites mtime and atime but NOT ctime, and
#     ctime cannot be moved backwards without root -- so backdating a planted
#     file no longer hides it.
#   * a path-set delta against a pre-run inventory kept in $CTL, which catches
#     deletions and anything whose timestamps were manipulated.
# .gitignore is NEVER used to filter this list: a self-ignoring .gitignore was a
# working hiding primitive. Ignored files are annotated, never removed.
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" status --porcelain > "$OUT/status.after"  2>/dev/null
  git -C "$WORKSPACE" diff               > "$OUT/unstaged.diff" 2>/dev/null
  git -C "$WORKSPACE" diff --cached      > "$OUT/staged.diff"   2>/dev/null
fi
find "$WORKSPACE" -type f -not -path "*/.git/*" -print 2>/dev/null | sort > "$CTL/files.after"
{
  # created or modified during the run (ctime-based)
  find "$WORKSPACE" -type f -not -path "*/.git/*" -newercm "$MARKER" -print 2>/dev/null
  # appeared during the run (path-set delta; redundant with the above by design)
  comm -13 "$CTL/files.before" "$CTL/files.after" 2>/dev/null
} 2>/dev/null | sort -u > "$CTL/changed.abs"
: > "$OUT/changed.txt"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rel="${f#"$WORKSPACE"/}"
  note=""
  if [[ "$IS_GIT" == "1" ]] && git -C "$WORKSPACE" check-ignore -q -- "$rel" 2>/dev/null; then
    note="   [gitignored]"
  fi
  printf '%s%s\n' "$rel" "$note" >> "$OUT/changed.txt"
done < "$CTL/changed.abs"
# deletions
comm -23 "$CTL/files.before" "$CTL/files.after" 2>/dev/null | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf '%s   [DELETED]\n' "${f#"$WORKSPACE"/}" >> "$OUT/changed.txt"
done

# ---- Did the agent touch anything outside the workspace? --------------------
ESCAPE_CHECKED=0; ESCAPED=""
if [[ "$HAVE_TRACE" == "1" && -s "$OUT/actions.txt" ]]; then
  ESCAPE_CHECKED=1
  # A path counts as inside only if it starts with the workspace AND contains no
  # upward traversal -- `<workspace>/../../etc/shadow` starts with the workspace.
  grep -oE '"file_path":"[^"]+"' "$OUT/actions.txt" 2>/dev/null \
    | sed 's/"file_path":"//; s/"$//' | sort -u \
    | while IFS= read -r fp; do
        case "$fp" in
          */../*|*/..) echo "$fp   [upward traversal]"; continue ;;
          /*) : ;;
          *) echo "$fp   [relative path -- could not be resolved]"; continue ;;
        esac
        # Normalize before comparing. /var/folders and /private/var/folders name
        # the same directory on macOS, and an unnormalized compare reports a
        # perfectly ordinary in-workspace edit as an escape -- a false alarm that
        # trains the reader to ignore the loudest line in the report.
        d="$(dirname "$fp")"
        if [[ -d "$d" ]]; then
          real="$(cd "$d" 2>/dev/null && pwd -P)/$(basename "$fp")"
        else
          real="$fp"
        fi
        case "$real" in
          "$WORKSPACE"/*) ;;
          *) echo "$fp" ;;
        esac
      done > "$OUT/outside.txt" 2>/dev/null
  [[ -s "$OUT/outside.txt" ]] && ESCAPED=1
fi

# ---- Compact report ---------------------------------------------------------
cap() { head -c 4000 "$1"; [[ $(wc -c < "$1") -gt 4000 ]] && echo "  [...truncated, full text: $1]"; }

echo "=== swe2 run $RUN_ID ==="
echo "status:     $STATUS"
echo "model:      $MODEL (mode: $MODE, sandbox: $([[ $SANDBOX == 1 ]] && echo on || echo OFF))"
echo "workspace:  $WORKSPACE$([[ -s "$OUT/branch" ]] && echo "  [branch: $(cat "$OUT/branch")]")"
[[ -n "$SESSION_ID" ]] && echo "session_id: $SESSION_ID   (resume: --resume $SESSION_ID)"
echo "artifacts:  $OUT   (elapsed: ${ELAPSED}s)"
if [[ -n "$TIMED_OUT" ]]; then
  echo "!! TIMED OUT after ${TIMEOUT}s and was killed -- any work below is PARTIAL !!"
fi
if [[ "$IS_GIT" == "1" && -s "$CTL/status.before" ]]; then
  echo "note:       the worktree was ALREADY dirty before this run"
  echo "            ($(wc -l < "$CTL/status.before" | tr -d ' ') pre-existing entries; 'files touched' below covers only this run)"
fi
if [[ -s "$OUT/metrics.json" ]]; then echo "--- metrics ---"; cat "$OUT/metrics.json"; fi
if [[ -s "$OUT/tools.txt" ]]; then echo "--- tool calls ---"; head -20 "$OUT/tools.txt"; fi

echo "--- files touched ---"
if [[ -s "$OUT/changed.txt" ]]; then head -50 "$OUT/changed.txt"
  [[ $(wc -l < "$OUT/changed.txt") -gt 50 ]] && echo "  [...$(wc -l < "$OUT/changed.txt") total, see $OUT/changed.txt]"
else echo "(none)"; fi
if [[ "$IS_GIT" == "1" ]]; then
  echo "--- diffstat ---"
  git -C "$WORKSPACE" diff --stat 2>/dev/null | head -20
  UNTRACKED="$(git -C "$WORKSPACE" ls-files --others --exclude-standard 2>/dev/null | head -20)"
  [[ -n "$UNTRACKED" ]] && { echo "--- untracked files now in worktree ---"; echo "$UNTRACKED"; }
fi

# The absence of an escape report must never read as a clean result.
if [[ "$ESCAPE_CHECKED" == "1" ]]; then
  if [[ -n "$ESCAPED" ]]; then
    echo "--- !! PATHS TOUCHED OUTSIDE WORKSPACE !! ---"; head -20 "$OUT/outside.txt"
  else
    echo "escape check: performed, no out-of-workspace paths in the trace"
  fi
else
  echo "escape check: NOT PERFORMED ($TRACE_WHY) -- out-of-workspace writes were not ruled out"
fi

if [[ -s "$OUT/stderr.txt" ]]; then echo "--- stderr (tail) ---"; tail -20 "$OUT/stderr.txt"; fi
if [[ -s "$OUT/answer.txt" ]] && grep -q '^RESULT[[:space:]]*$' "$OUT/answer.txt" 2>/dev/null; then
  echo "--- agent result (self-reported, VERIFY IT) ---"
  sed -n '/^RESULT[[:space:]]*$/,$p' "$OUT/answer.txt" | tail -n +2 | head -20
  echo "--- full answer: $OUT/answer.txt ---"
else
  echo "--- agent answer (no RESULT block returned) ---"
  [[ -s "$OUT/answer.txt" ]] && cap "$OUT/answer.txt"
fi

exit $STATUS
