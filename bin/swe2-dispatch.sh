#!/usr/bin/env bash
# Dispatch a bounded task to a SWE-2 agent (Cognition `devin` CLI) and collect a
# compact report the calling session can trust.
#
#   swe2-dispatch.sh --workspace <dir> --brief <file> [--model swe-2-max]
#                    [--mode smart|accept-edits|auto] [--out <dir>] [--resume <id>]
#                    [--scratch] [--no-sandbox] [--raw] [--allow-write <dir>]...
#                    [--timeout <seconds>]
#                    --verify <cmd> [--regress <cmd>] [--protect <glob>]...
#                    [--scope <glob>]... [--max-files N] [--max-lines N]
#                    [--verify-may-pass] [--simplify <cmd>] [--attempts N]
#
# THE CENTRAL INVARIANT
#   Nothing the report depends on is ever written where the agent can reach it,
#   and the report is taken only after the agent's entire process tree is dead.
#   Three review rounds defeated earlier designs that violated one or the other:
#   symlinking a report file to /dev/null, poisoning a baseline, injecting report
#   text through a value read back from the run dir, and writing from a detached
#   child after the measurement was taken.
#
#   The agent gets exactly one writable directory of its own, $OUT/agent, for its
#   export and temp files. Everything else the script produces lives in $CTL --
#   outside the workspace, outside $OUT, outside every --allow-write path -- and
#   is published into $OUT only once the run is over.
#
# CONFINEMENT
#   * --workspace must be the root of a *linked git worktree*: its git dir must be
#     <common-dir>/worktrees/<name>. A primary checkout, a submodule and a planted
#     `.git` file are all refused -- a `.git` FILE alone is not sufficient, since a
#     submodule's is also a file pointing at a complete, committable git dir.
#   * Writes are confined by a macOS seatbelt profile. No git directory is granted,
#     so `git add`, `git commit` and `git update-index --assume-unchanged` all fail
#     while read-only git keeps working.
#   * Paths interpolated into that profile are rejected if they contain characters
#     that could terminate an S-expression.
#   * --scratch permits a non-git directory, but only under the temp root.
#   * --mode is an allowlist; `dangerous` and anything unrecognized is refused.
#
# Exit status is the agent's own, or 2 for a usage/guard failure.

set -uo pipefail

# git's rev-parse honors these, so an inherited value would make the guard inspect
# a repository that has nothing to do with --workspace. They are also routinely set
# inside git hooks, so this is not only a hostile-caller concern.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES 2>/dev/null

ORIG_ARGS=("$@")
DEVIN="${DEVIN_BIN:-$HOME/.local/bin/devin}"
MODEL="swe-2-max"
MODE="smart"
WORKSPACE=""; BRIEF=""; OUT=""; RESUME=""
SCRATCH=0; SANDBOX=1; RAW=0; TIMEOUT=1800
VERIFY=""; REGRESS=""; VERIFY_MAY_PASS=0; SIMPLIFY=""
MAX_FILES=0; MAX_LINES=0; ATTEMPTS=1
EXTRA_WRITES=(); PROTECT=(); SCOPE=()

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

# Render an untrusted string as one printable line. Used for every value that has
# been anywhere near the agent: filenames, and anything read back out of $OUT.
esc() {
  LC_ALL=C perl -pe 's/\\/\\\\/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g; s/[\x00-\x1f\x7f]/sprintf("\\x%02x",ord($&))/ge' 2>/dev/null \
    || tr -d '\000-\010\013\014\016-\037\177'
}
# One untrusted value -> one capped, printable line.
esc_one() { printf '%s' "$1" | esc | head -c 300 | head -1; }
# A multi-line untrusted block: newlines survive so it stays readable, every other
# control character is stripped, and the "| " prefix means injected text cannot
# impersonate one of our own report headings.
esc_block() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null | sed 's/^/  | /'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)   need_val "$@"; WORKSPACE="$2"; shift 2 ;;
    --brief)       need_val "$@"; BRIEF="$2";     shift 2 ;;
    --model)       need_val "$@"; MODEL="$2";     shift 2 ;;
    --mode)        need_val "$@"; MODE="$2";      shift 2 ;;
    --out)         need_val "$@"; OUT="$2";       shift 2 ;;
    --resume)      need_val "$@"; RESUME="$2";    shift 2 ;;
    --timeout)     need_val "$@"; TIMEOUT="$2";   shift 2 ;;
    --allow-write) need_val "$@"; EXTRA_WRITES+=("$2"); shift 2 ;;
    --scratch)     SCRATCH=1; shift 1 ;;
    --no-sandbox)  SANDBOX=0; shift 1 ;;
    --raw)         RAW=1;     shift 1 ;;
    --verify)      need_val "$@"; VERIFY="$2";   shift 2 ;;
    --regress)     need_val "$@"; REGRESS="$2";  shift 2 ;;
    --protect)     need_val "$@"; PROTECT+=("$2"); shift 2 ;;
    --scope)       need_val "$@"; SCOPE+=("$2");   shift 2 ;;
    --max-files)   need_val "$@"; MAX_FILES="$2"; shift 2 ;;
    --max-lines)   need_val "$@"; MAX_LINES="$2"; shift 2 ;;
    --verify-may-pass) VERIFY_MAY_PASS=1; shift 1 ;;
    --simplify)    need_val "$@"; SIMPLIFY="$2"; shift 2 ;;
    --attempts)    need_val "$@"; ATTEMPTS="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "$DEVIN"     ]] || die "devin CLI not found at $DEVIN"
[[ -n "$WORKSPACE" ]] || die "--workspace is required"
[[ -d "$WORKSPACE" ]] || die "--workspace must be an existing directory"
[[ -f "$BRIEF"     ]] || die "--brief must be an existing file"

# The brief is the dominant quality lever. Adding explicit expectations and
# constraints moved "did not regress previously-passing tests outside the change
# scope" from 7.8% to 88.1% in a controlled ablation, while barely changing
# whether the task got done at all. Requiring the sections is the only way the
# lever does not get quietly skipped on a busy day.
if [[ "$RAW" != "1" ]]; then
  MISSING=""
  for sec in Goal Expectations Constraints "Out of scope" "Files in scope" Acceptance; do
    grep -qiE "^[[:space:]]*(#+[[:space:]]*)?${sec}[[:space:]]*:?[[:space:]]*$|^[[:space:]]*(#+[[:space:]]*)?${sec}[[:space:]]*:" "$BRIEF" \
      || MISSING="$MISSING
              - $sec"
  done
  if [[ -n "$MISSING" ]]; then
    die "the brief is missing required sections:$MISSING

              A brief must state what 'done' means before the agent starts. Add each
              section as a heading or 'Name:' line. Out of scope is the one that buys
              the most -- it is what keeps the agent from touching unrelated code.
              Acceptance must name the exact command that proves success.

              Use --raw only for a throwaway dispatch where none of this matters."
  fi
fi
case "$MODE" in smart|accept-edits|auto) : ;;
  *) die "--mode must be one of: smart, accept-edits, auto (got '$MODE')" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds (got '$TIMEOUT')" ;; esac
[[ "$TIMEOUT" -gt 0 ]] || die "--timeout must be greater than zero"

case "$ATTEMPTS" in ''|*[!0-9]*) die "--attempts must be a whole number" ;; esac
[[ "$ATTEMPTS" -ge 1 ]] || die "--attempts must be at least 1"

WORKSPACE="$(cd "$WORKSPACE" && pwd -P)" || die "cannot resolve --workspace"

# ---- Best-of-N ---------------------------------------------------------------
# Frontier agents fail ~30-50% of tasks they CAN solve on a re-roll, so a second
# attempt buys a re-roll on an unstable task -- not a better model. Selection is
# by the regression suite FIRST (Anthropic's published recipe), then by smallest
# diff. Ranked survivors are handed back for pairwise comparison: a scoring judge
# recovered only 21% of the oracle gap because coarse scores tie 66.5% of the time.
if [[ "$ATTEMPTS" -gt 1 ]]; then
  git -C "$WORKSPACE" rev-parse --absolute-git-dir >/dev/null 2>&1 \
    || die "--attempts requires a git worktree"
  BASE="$(git -C "$WORKSPACE" rev-parse HEAD)"
  RUN_ROOT="${OUT:-${TMPDIR:-/tmp}/swe2-runs/$(date +%Y%m%d-%H%M%S)-$$}"
  mkdir -p "$RUN_ROOT" || exit 2
  RUN_ROOT="$(cd "$RUN_ROOT" && pwd -P)"
  echo "=== best-of-$ATTEMPTS from $BASE ==="
  WINNER=""; WINNER_LINES=""; SUMMARY="$RUN_ROOT/attempts.txt"; : > "$SUMMARY"
  for i in $(seq 1 "$ATTEMPTS"); do
    AWT="$RUN_ROOT/attempt-$i/wt"; AOUT="$RUN_ROOT/attempt-$i/out"
    mkdir -p "$(dirname "$AWT")" "$AOUT"
    git -C "$WORKSPACE" worktree add --detach -q "$AWT" "$BASE" 2>/dev/null \
      || { echo "attempt $i: could not create worktree" >> "$SUMMARY"; continue; }
    # Index loop, not word-splitting: --verify carries a command with spaces.
    SUB=(); nargs=${#ORIG_ARGS[@]}; j=0
    while [[ "$j" -lt "$nargs" ]]; do
      a="${ORIG_ARGS[$j]}"
      case "$a" in
        --attempts)  j=$((j+2)); continue ;;
        --workspace) SUB+=(--workspace "$AWT"); j=$((j+2)); continue ;;
        --out)       SUB+=(--out "$AOUT");      j=$((j+2)); continue ;;
      esac
      SUB+=("$a"); j=$((j+1))
    done
    echo "--- attempt $i/$ATTEMPTS ---"
    "$0" "${SUB[@]}" > "$AOUT/report.txt" 2>&1
    V="$(grep -m1 -A1 '^--- verdict ---$' "$AOUT/report.txt" 2>/dev/null | tail -1)"
    L="$(git -C "$AWT" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {print a+d+0}')"
    F="$(git -C "$AWT" diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
    git -C "$AWT" diff > "$AOUT/candidate.patch" 2>/dev/null
    printf 'attempt %s  %-70s  %s files, %s lines  %s\n' "$i" "${V:-NO VERDICT}" "$F" "$L" "$AOUT/candidate.patch" >> "$SUMMARY"
    case "$V" in
      VERIFIED*) if [[ -z "$WINNER_LINES" || "$L" -lt "$WINNER_LINES" ]]; then
                   WINNER="$AOUT/candidate.patch"; WINNER_LINES="$L"; fi ;;
    esac
  done
  echo
  echo "=== attempts ==="; cat "$SUMMARY"
  echo
  if [[ -n "$WINNER" ]]; then
    cp "$WINNER" "$RUN_ROOT/winner.patch"
    echo "winner (VERIFIED, smallest diff): $RUN_ROOT/winner.patch"
    echo "Apply with: git -C <your worktree> apply $RUN_ROOT/winner.patch"
    echo "Other VERIFIED candidates above are worth a pairwise read before you commit --"
    echo "smallest-diff is a tiebreak, not a judgement."
  else
    echo "NO attempt verified. This is a task-level failure, not $ATTEMPTS separate ones:"
    echo "the brief, the acceptance command, or the task decomposition is the problem."
  fi
  echo "worktrees kept for inspection under $RUN_ROOT (git worktree remove when done)"
  exit 0
fi
safe_for_profile "$WORKSPACE" || die "--workspace path contains characters that cannot be sandboxed safely"

# ---- Confinement guard -------------------------------------------------------
GITDIR=""
TOPLEVEL="$(git -C "$WORKSPACE" rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$TOPLEVEL" ]]; then
  [[ "$SCRATCH" == "1" ]] || die "$WORKSPACE is not a git worktree. Dispatch is confined to a
              task-owned LINKED worktree. Use --scratch only for a throwaway directory
              under the temp root."
  TMPROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  case "$WORKSPACE/" in "$TMPROOT"/*|/private/tmp/*|/tmp/*) : ;;
    *) die "--scratch is limited to directories under the temp root; $WORKSPACE is not" ;; esac
  IS_GIT=0
else
  TOPLEVEL="$(cd "$TOPLEVEL" && pwd -P)"
  [[ "$TOPLEVEL" == "$WORKSPACE" ]] || die "--workspace must be the worktree ROOT ($TOPLEVEL), not a subdirectory"
  GITDIR="$(git -C "$WORKSPACE" rev-parse --absolute-git-dir 2>/dev/null)"
  COMMON="$(git -C "$WORKSPACE" rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$GITDIR" && -n "$COMMON" ]] || die "cannot resolve the git directory for $WORKSPACE"
  case "$COMMON" in /*) : ;; *) COMMON="$WORKSPACE/$COMMON" ;; esac
  GITDIR="$(cd "$GITDIR" && pwd -P)" || die "cannot resolve git dir"
  COMMON="$(cd "$COMMON" && pwd -P)" || die "cannot resolve git common dir"
  case "$GITDIR" in
    "$COMMON"/worktrees/*) : ;;
    *) die "$WORKSPACE is not a linked git worktree.
              git dir:    $GITDIR
              common dir: $COMMON
              A linked worktree's git dir must be <common>/worktrees/<name>. Primary
              checkouts, submodules and planted .git files are refused because their
              git directory would be writable and could be committed to. Create one
              with 'git worktree add'." ;;
  esac
  # A repo laid out so its common dir sits inside the workspace would become
  # writable through the workspace grant, restoring commit capability.
  case "$COMMON/" in "$WORKSPACE"/*) die "this repository's git common dir is inside the workspace; refusing" ;; esac
  IS_GIT=1
fi

if [[ -z "$VERIFY" && "$RAW" != "1" ]]; then
  die "--verify <command> is required.

              The agent's RESULT block is self-reported, and across ~11,800 measured
              trajectories 'claims done, ground truth disagrees' was 45-78% of failures
              -- with LLM judges barely better than chance at spotting it. The only
              thing that settles it is running the acceptance command here, outside the
              sandbox. Pass the command from your brief's Acceptance section.

              Use --raw for a throwaway dispatch where nothing will be verified."
fi
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUT="${OUT:-${TMPDIR:-/tmp}/swe2-runs/$RUN_ID}"
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd -P)" || exit 2
safe_for_profile "$OUT" || die "--out path contains characters that cannot be sandboxed safely"
case "$OUT/" in "$WORKSPACE"/*) die "--out must not be inside the workspace ($OUT); the agent can write there" ;; esac

# Resolve --allow-write up front: needed to prove $CTL is out of reach.
GRANTS=()
for extra in ${EXTRA_WRITES[@]+"${EXTRA_WRITES[@]}"}; do
  safe_for_profile "$extra" || die "--allow-write path contains characters that cannot be sandboxed safely: $extra"
  [[ -e "$extra" ]] || die "--allow-write path does not exist: $extra"
  r="$(cd "$extra" 2>/dev/null && pwd -P)" || die "--allow-write must be a directory: $extra"
  safe_for_profile "$r" || die "--allow-write path contains characters that cannot be sandboxed safely: $extra"
  case "$OUT/" in "$r"/*) die "--out must not be inside an --allow-write path ($r)" ;; esac
  GRANTS+=("$r")
done

# ---- Control directory: everything the report trusts -------------------------
# Must be outside the workspace, outside $OUT, and outside every granted path.
# Granting the temp root (the documented remedy for a blocked toolchain cache)
# previously handed the agent both change detectors' baselines.
CTL="$(mktemp -d "${TMPDIR:-/tmp}/.swe2-ctl-XXXXXX")" || exit 2
CTL="$(cd "$CTL" && pwd -P)" || exit 2
chmod 700 "$CTL" 2>/dev/null
ctl_is_reachable() {
  case "$CTL/" in "$WORKSPACE"/*|"$OUT"/*) return 0 ;; esac
  for g in ${GRANTS[@]+"${GRANTS[@]}"}; do case "$CTL/" in "$g"/*) return 0 ;; esac; done
  return 1
}
if ctl_is_reachable; then
  CTL2="$(mktemp -d "/tmp/.swe2-ctl-XXXXXX" 2>/dev/null)" && { rm -rf "$CTL"; CTL="$(cd "$CTL2" && pwd -P)"; chmod 700 "$CTL"; }
  ctl_is_reachable && { rm -rf "$CTL"; die "cannot place the control directory outside every writable path.
              A granted path covers the temp root. Narrow --allow-write."; }
fi

# The agent's own writable directory -- the ONLY thing granted besides the worktree.
AGENT_DIR="$OUT/agent"; mkdir -p "$AGENT_DIR/tmp" || exit 2
EXPORT_JSON="$AGENT_DIR/export.json"
rm -f "$EXPORT_JSON" 2>/dev/null

# One dispatch per worktree; two agents in one tree make "what changed" meaningless.
LOCK="${TMPDIR:-/tmp}/.swe2-lock-$(printf '%s' "$WORKSPACE" | cksum | tr -d ' /')"
if ! mkdir "$LOCK" 2>/dev/null; then
  OWNER="$(cat "$LOCK/pid" 2>/dev/null)"
  if [[ -n "$OWNER" ]] && kill -0 "$OWNER" 2>/dev/null; then
    rm -rf "$CTL"; die "another dispatch (pid $OWNER) is already running in this worktree."
  fi
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { rm -rf "$CTL"; die "cannot acquire the dispatch lock at $LOCK"; }
fi
printf '%s' "$$" > "$LOCK/pid"
cleanup() { [[ -n "${AGENT_PGID:-}" ]] && kill -- -"$AGENT_PGID" 2>/dev/null; rm -rf "$CTL" "$LOCK"; }
trap cleanup EXIT INT TERM

# ---- Inventory the tree BEFORE the run --------------------------------------
# Symlinks are included: -type f alone misses a planted secrets_link -> /etc/passwd.
# Paths are stored escaped, one per line, so a newline in a filename cannot forge
# an extra entry and set operations stay line-oriented.
inventory() {
  find "$WORKSPACE" \( -type f -o -type l \) -not -path "*/.git/*" -print0 2>/dev/null \
    | LC_ALL=C perl -0ne 'chomp; s/\\/\\\\/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g; s/[\x00-\x1f\x7f]/sprintf("\\x%02x",ord($&))/ge; print "$_\n"' 2>/dev/null \
    | LC_ALL=C sort
}
inventory > "$CTL/files.before"
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" rev-parse HEAD              > "$CTL/head.before"   2>/dev/null
  git -C "$WORKSPACE" status --porcelain          > "$CTL/status.before" 2>/dev/null
  git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD > "$CTL/branch"        2>/dev/null
fi
sleep 1
MARKER="$CTL/start-marker"; touch "$MARKER"

# ---- Brief composition -------------------------------------------------------
SENT_BRIEF="$BRIEF"
if [[ "$RAW" != "1" ]]; then
  SENT_BRIEF="$CTL/brief.sent.md"
  {
    echo "You are working in a dedicated git worktree at: $WORKSPACE"
    echo "That directory is your current working directory and the ONLY place you may write."
    echo
    echo "## Standing constraints"
    echo
    echo "- Write only inside the worktree. Writes elsewhere are blocked by the OS, not just by policy."
    echo "- Do NOT stage, commit, push, branch, or amend. \`git add\` will fail by design; that is expected, not a problem to solve. Leave your work as uncommitted changes."
    echo "- Read-only git and the network are available. Looking up how this was solved elsewhere is fine; what matters is that the change is right for THIS codebase at THIS commit. Say where a borrowed approach came from."
    echo "- Change only what the task requires. No unrelated refactors, reformatting, or added comments on code you did not touch."
    echo "- Never weaken, skip, or delete a test to make things pass, and never hard-code for a specific test input."
    echo "- If the task cannot be done as specified -- the requirement conflicts with the tests, the spec is contradictory, or the environment is missing something you may not install -- STOP and report \`status: infeasible\` with the reason. That is a correct, useful outcome. Do not invent a workaround to appear successful."
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
    echo "reasoning: <one line: what you actually did and why you believe it works>"
    echo "status: done | partial | blocked | infeasible"
    echo "files: <comma-separated paths you changed, relative to the worktree, or none>"
    echo "verified: <the exact command you ran to check your work and its real outcome, or 'not run'>"
    echo "notes: <one line: anything skipped, uncertain, or that the reviewer must know>"
  } > "$SENT_BRIEF"
fi

DEVIN_ARGS=(-p --prompt-file "$SENT_BRIEF" --model "$MODEL" --permission-mode "$MODE"
            --respect-workspace-trust false --export "$EXPORT_JSON")
[[ -n "$RESUME" ]] && DEVIN_ARGS+=(--resume "$RESUME")

# devin's own --sandbox is NOT used: it forces the autonomous permission mode,
# which in non-interactive mode rejects every edit needing confirmation.
SANDBOX_CMD=()
if [[ "$SANDBOX" == "1" ]]; then
  command -v sandbox-exec >/dev/null 2>&1 || die "sandbox-exec not available; re-run with --no-sandbox to dispatch unconfined"
  DEVIN_STATE="$HOME/.local/share/devin"; DEVIN_CFG="$HOME/.config/devin"
  safe_for_profile "$DEVIN_STATE" && safe_for_profile "$DEVIN_CFG" || die "home directory path cannot be sandboxed safely"
  {
    echo '(version 1)'; echo '(allow default)'; echo '(deny file-write*)'
    echo '(allow file-write*'
    echo "  (subpath \"$WORKSPACE\")"
    # Only the agent's own directory -- NOT $OUT, which holds the published report.
    echo "  (subpath \"$AGENT_DIR\")"
    echo "  (subpath \"$DEVIN_STATE\")"
    echo "  (subpath \"$DEVIN_CFG\")"
    for g in ${GRANTS[@]+"${GRANTS[@]}"}; do echo "  (subpath \"$g\")"; done
    echo '  (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr")'
    echo '  (regex #"^/dev/tty"))'
  } > "$CTL/sandbox.sb"
  SANDBOX_CMD=(sandbox-exec -f "$CTL/sandbox.sb")
fi

# ---- Verification ------------------------------------------------------------
# Run by the wrapper, in the workspace, OUTSIDE the sandbox. Never by the agent.
run_check() {  # run_check <label> <command> -> exit code; output to $CTL/<label>.log
  local label="$1" cmd="$2"
  ( cd "$WORKSPACE" && eval "$cmd" ) > "$CTL/$label.log" 2>&1
  local rc=$?
  echo "$rc" > "$CTL/$label.rc"
  return $rc
}

VERIFY_BEFORE=""; VERIFY_AFTER=""; REGRESS_BEFORE=""; REGRESS_AFTER=""; VERDICT=""
if [[ -n "$VERIFY" ]]; then
  run_check verify-before "$VERIFY"; VERIFY_BEFORE=$?
  if [[ "$VERIFY_BEFORE" -eq 0 && "$VERIFY_MAY_PASS" != "1" ]]; then
    die "the acceptance command already passes before the agent has done anything.

              Either the task is already done, or the command does not actually cover
              it -- and a run that starts green can only end green, which proves
              nothing. Tighten the command so it fails for the reason you are
              dispatching.

              Pass --verify-may-pass when this is intentional (a refactor, where the
              suite is expected to stay green throughout)."
  fi
fi
if [[ -n "$REGRESS" ]]; then
  run_check regress-before "$REGRESS"; REGRESS_BEFORE=$?
  [[ "$REGRESS_BEFORE" -ne 0 ]] && echo "swe2-dispatch: warning: the regression command already fails before the run; it cannot show a regression" >&2
fi

# ---- Run ---------------------------------------------------------------------
cd "$WORKSPACE" || exit 2
STARTED_AT="$(date '+%s')"
set -m   # each job gets its own process group (PGID == PID); macOS has no setsid
TMPDIR="$AGENT_DIR/tmp" ${SANDBOX_CMD[@]+"${SANDBOX_CMD[@]}"} "$DEVIN" "${DEVIN_ARGS[@]}" \
  > "$CTL/answer.txt" 2> "$CTL/stderr.txt" &
AGENT_PID=$!
AGENT_PGID=$AGENT_PID
set +m
( sleep "$TIMEOUT"
  : > "$CTL/timed-out"
  kill -TERM -- -"$AGENT_PGID" 2>/dev/null && { sleep 5; kill -KILL -- -"$AGENT_PGID" 2>/dev/null; }
) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$AGENT_PID"; STATUS=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null

# Reap the whole process group BEFORE measuring. A detached `nohup ... &` child
# otherwise writes to the worktree after the inventory is taken, so the report
# says "clean" and the plant appears seconds later.
kill -TERM -- -"$AGENT_PGID" 2>/dev/null
sleep 1
kill -KILL -- -"$AGENT_PGID" 2>/dev/null
ORPHANS="$(pgrep -g "$AGENT_PGID" 2>/dev/null | wc -l | tr -d ' ')"
AGENT_PGID=""

ELAPSED=$(( $(date '+%s') - STARTED_AT ))
# A sentinel, not a heuristic on the exit code: the old test misclassified in
# both directions.
TIMED_OUT=""
[[ -e "$CTL/timed-out" ]] && TIMED_OUT=1

# ---- Parse the trace (agent-written: untrusted) ------------------------------
SESSION_ID=""; HAVE_TRACE=0; TRACE_WHY="no export.json was written"
if [[ -s "$EXPORT_JSON" ]]; then
  if command -v jq >/dev/null 2>&1; then
    HAVE_TRACE=1
    SESSION_ID="$(esc_one "$(jq -r '.session_id // ""' "$EXPORT_JSON" 2>/dev/null)")"
    jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls|length)>0)
           | .tool_calls[] | .function_name // .function.name // .name // "tool"' \
       "$EXPORT_JSON" 2>/dev/null | sort | uniq -c | sort -rn | head -40 > "$CTL/tools.txt"
    jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls|length)>0)
           | .tool_calls[] | "\(.function_name // "tool")\t\(.arguments|tostring)"' \
       "$EXPORT_JSON" 2>/dev/null > "$CTL/actions.txt"
    jq -r '.final_metrics // {}' "$EXPORT_JSON" 2>/dev/null | head -c 2000 > "$CTL/metrics.json"
  else
    TRACE_WHY="jq is not installed"
  fi
fi
[[ "$HAVE_TRACE" == "1" && ! -s "$CTL/actions.txt" ]] && TRACE_WHY="the trace recorded no tool calls with arguments"

# ---- What changed ------------------------------------------------------------
if [[ "$IS_GIT" == "1" ]]; then
  git -C "$WORKSPACE" status --porcelain > "$CTL/status.after"  2>/dev/null
  git -C "$WORKSPACE" diff               > "$CTL/unstaged.diff" 2>/dev/null
  git -C "$WORKSPACE" diff --cached      > "$CTL/staged.diff"   2>/dev/null
fi
inventory > "$CTL/files.after"
# ctime, not mtime: `touch -t` cannot move ctime backwards, so backdating a planted
# or edited file does not hide it.
find "$WORKSPACE" \( -type f -o -type l \) -not -path "*/.git/*" -newercm "$MARKER" -print0 2>/dev/null \
  | LC_ALL=C perl -0ne 'chomp; s/\\/\\\\/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g; s/[\x00-\x1f\x7f]/sprintf("\\x%02x",ord($&))/ge; print "$_\n"' 2>/dev/null \
  | LC_ALL=C sort > "$CTL/touched.ctime"
LC_ALL=C comm -13 "$CTL/files.before" "$CTL/files.after" > "$CTL/created" 2>/dev/null
LC_ALL=C comm -23 "$CTL/files.before" "$CTL/files.after" > "$CTL/deleted" 2>/dev/null
LC_ALL=C sort -u "$CTL/touched.ctime" "$CTL/created" > "$CTL/changed.paths" 2>/dev/null

# Annotations are a fixed-width PREFIX, never a suffix: a file named
# "decoy.py   [DELETED]" must not be able to impersonate an annotation.
WS_ESC="$(printf '%s' "$WORKSPACE" | esc)"
: > "$CTL/changed.txt"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rel="${f#"$WS_ESC"/}"
  tag="changed   "
  if [[ "$IS_GIT" == "1" ]] && git -C "$WORKSPACE" check-ignore -q -- "$rel" 2>/dev/null; then
    tag="changed*  "   # * = gitignored; never filtered out, only marked
  fi
  printf '%s%s\n' "$tag" "$rel" >> "$CTL/changed.txt"
done < "$CTL/changed.paths"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf 'DELETED   %s\n' "${f#"$WS_ESC"/}" >> "$CTL/changed.txt"
done < "$CTL/deleted"

# ---- Hook files the agent could plant to execute on a LATER run --------------
# The devin CLI loads lifecycle hooks from .devin/hooks.v1.json, .devin/config.json
# and .claude/settings*.json in the workspace. The agent can write all of those, so
# they are a persistence vector: config-shaped, easy to commit by accident, and
# executed by the NEXT dispatch. They must never appear as ordinary changed files.
: > "$CTL/hookfiles.txt"
for hf in .devin/hooks.v1.json .devin/config.json .devin/mcp_config.json \
          .claude/settings.json .claude/settings.local.json; do
  [[ -e "$WORKSPACE/$hf" ]] || continue
  if grep -qxF "changed   $hf" "$CTL/changed.txt" 2>/dev/null || \
     grep -qxF "changed*  $hf" "$CTL/changed.txt" 2>/dev/null; then
    echo "$hf   (created or modified by THIS run)" >> "$CTL/hookfiles.txt"
  else
    echo "$hf   (pre-existing)" >> "$CTL/hookfiles.txt"
  fi
done

# ---- Out-of-workspace touches ------------------------------------------------
ESCAPE_CHECKED=0; ESCAPED=""
if [[ "$HAVE_TRACE" == "1" && -s "$CTL/actions.txt" ]]; then
  ESCAPE_CHECKED=1
  # Every string leaf that looks like a path, under any key -- not just file_path.
  jq -r '.steps[]? | select(.tool_calls != null and (.tool_calls|length)>0)
         | .tool_calls[] | .arguments | .. | strings | select(test("/"))' \
     "$EXPORT_JSON" 2>/dev/null | sort -u \
    | while IFS= read -r fp; do
        case "$fp" in
          */../*|*/..) printf 'traversal %s\n' "$(esc_one "$fp")"; continue ;;
          /*) : ;;
          # A relative path is what an ordinary in-workspace edit produces. It is
          # not evidence of an escape, and firing the loudest line in the report on
          # normal runs is how that line gets ignored when it matters.
          *) continue ;;
        esac
        d="$(dirname "$fp")"
        if [[ -d "$d" ]]; then real="$(cd "$d" 2>/dev/null && pwd -P)/$(basename "$fp")"; else real="$fp"; fi
        case "$real" in "$WORKSPACE"/*) ;; *) printf 'outside   %s\n' "$(esc_one "$fp")" ;; esac
      done > "$CTL/outside.txt" 2>/dev/null
  [[ -s "$CTL/outside.txt" ]] && ESCAPED=1
fi

# ---- Post-run verification ---------------------------------------------------
if [[ -n "$VERIFY" ]]; then
  run_check verify-after "$VERIFY"; VERIFY_AFTER=$?
fi
if [[ -n "$REGRESS" ]]; then
  run_check regress-after "$REGRESS"; REGRESS_AFTER=$?
fi

# Did it pass by editing the tests? Rebuild the candidate on a clean checkout with
# the protected paths restored from base, and re-run. This is the mechanism
# SWE-bench actually uses -- revert, not prevent.
GAMED=""
if [[ -n "$VERIFY" && "$VERIFY_AFTER" -eq 0 && "$IS_GIT" == "1" && ${#PROTECT[@]} -gt 0 ]]; then
  git -C "$WORKSPACE" diff > "$CTL/candidate.patch" 2>/dev/null
  VWT="$CTL/verify-wt"
  if git -C "$WORKSPACE" worktree add --detach -q "$VWT" HEAD 2>/dev/null; then
    EXCL=()
    for g in "${PROTECT[@]}"; do EXCL+=("--exclude=$g"); done
    if [[ -s "$CTL/candidate.patch" ]]; then
      git -C "$VWT" apply "${EXCL[@]}" "$CTL/candidate.patch" 2>/dev/null
    fi
    # Untracked files the agent added, minus anything under a protected glob.
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      skip=""
      for g in "${PROTECT[@]}"; do case "$u" in $g) skip=1 ;; esac; done
      [[ -n "$skip" ]] && continue
      mkdir -p "$VWT/$(dirname "$u")" 2>/dev/null
      cp "$WORKSPACE/$u" "$VWT/$u" 2>/dev/null
    done < <(git -C "$WORKSPACE" ls-files --others --exclude-standard 2>/dev/null)
    ( cd "$VWT" && eval "$VERIFY" ) > "$CTL/verify-restored.log" 2>&1
    RESTORED_RC=$?
    echo "$RESTORED_RC" > "$CTL/verify-restored.rc"
    [[ "$RESTORED_RC" -ne 0 ]] && GAMED=1
    git -C "$WORKSPACE" worktree remove --force "$VWT" >/dev/null 2>&1
  fi
fi

# ---- Verdict -----------------------------------------------------------------
if [[ -z "$VERIFY" ]]; then VERDICT="UNVERIFIED (no acceptance command)"
elif [[ -n "$TIMED_OUT" ]]; then VERDICT="UNVERIFIED (timed out; work is partial)"
elif [[ -n "$GAMED" ]]; then VERDICT="GAMED (passes as written, fails with the original protected files restored)"
elif [[ "$VERIFY_AFTER" -ne 0 ]]; then VERDICT="NOT VERIFIED (acceptance command still fails)"
elif [[ -n "$REGRESS" && "$REGRESS_BEFORE" -eq 0 && "$REGRESS_AFTER" -ne 0 ]]; then
  VERDICT="REGRESSED (acceptance passes, but the regression command broke)"
else VERDICT="VERIFIED"; fi

# ---- Scope and size --------------------------------------------------------
: > "$CTL/out-of-scope.txt"
if [[ ${#SCOPE[@]} -gt 0 && -s "$CTL/changed.txt" ]]; then
  while IFS= read -r line; do
    rel="${line#* }"; rel="${rel#"${rel%%[![:space:]]*}"}"
    case "$rel" in */__pycache__/*|__pycache__/*) continue ;; esac
    inscope=""
    for g in "${SCOPE[@]}"; do case "$rel" in $g) inscope=1 ;; esac; done
    [[ -z "$inscope" ]] && echo "$rel" >> "$CTL/out-of-scope.txt"
  done < "$CTL/changed.txt"
fi
N_FILES=0; N_LINES=0
if [[ "$IS_GIT" == "1" ]]; then
  N_FILES=$(git -C "$WORKSPACE" diff --name-only 2>/dev/null | wc -l | tr -d " ")
  N_LINES=$(git -C "$WORKSPACE" diff --numstat 2>/dev/null | awk "{a+=\$1; d+=\$2} END {print a+d+0}")
fi

# ---- Optional post-hoc simplification ---------------------------------------
# Off by default. Quality-aware PROMPTING was measured not to slow code degradation
# while costing 30-48% more, but a post-hoc pass is a different intervention -- and
# it only survives if behavior is provably unchanged.
SIMPLIFIED=""
if [[ -n "$SIMPLIFY" && "$VERDICT" == "VERIFIED" ]]; then
  git -C "$WORKSPACE" diff > "$CTL/pre-simplify.patch" 2>/dev/null
  git -C "$WORKSPACE" ls-files --others --exclude-standard > "$CTL/pre-simplify.untracked" 2>/dev/null
  ( cd "$WORKSPACE" && eval "$SIMPLIFY" ) > "$CTL/simplify.log" 2>&1
  run_check verify-after-simplify "$VERIFY"; VS=$?
  RS=0; [[ -n "$REGRESS" ]] && { run_check regress-after-simplify "$REGRESS"; RS=$?; }
  if [[ "$VS" -eq 0 && "$RS" -eq 0 ]]; then
    SIMPLIFIED="kept"
  else
    # Behavior changed: put the verified diff back and keep it.
    git -C "$WORKSPACE" checkout -- . 2>/dev/null
    [[ -s "$CTL/pre-simplify.patch" ]] && git -C "$WORKSPACE" apply "$CTL/pre-simplify.patch" 2>/dev/null
    SIMPLIFIED="reverted (re-verification failed: acceptance exit $VS, regression exit $RS)"
  fi
fi

# ---- Quality signals from the trace -----------------------------------------
# Cheap, computed from what we already parsed. The best-supported one: a green run
# with many redundant edits has ~1-in-3 odds of being an incomplete fix (10.7% of
# 1,136 PASSING trajectories passed via weak process; blind-retry runs burned 11.4
# steps/instance vs 2.7 in clean ones).
: > "$CTL/signals.txt"
if [[ -s "$CTL/actions.txt" ]]; then
  THRASH="$(grep -oE '"file_path":"[^"]+"' "$CTL/actions.txt" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -1)"
  THRASH_N="$(echo "$THRASH" | awk "{print \$1+0}")"
  if [[ "${THRASH_N:-0}" -ge 8 ]]; then
    echo "repeated edits: $THRASH_N tool calls against one file -- thrashing; a green result here is ~1-in-3 an incomplete fix" >> "$CTL/signals.txt"
  fi
  if grep -qE 'git (log|show)|git diff [a-f0-9]{7,}|curl [^"]*github\.com' "$CTL/actions.txt" 2>/dev/null; then
    echo "consulted outside sources: the trace contains git-history or upstream lookups. Not a defect -- but check the change fits this commit rather than a later refactor." >> "$CTL/signals.txt"
  fi
fi
if [[ -s "$CTL/metrics.json" ]] && command -v jq >/dev/null 2>&1; then
  STEPS="$(jq -r '.total_steps // 0' "$CTL/metrics.json" 2>/dev/null)"
  [[ "${STEPS:-0}" -ge 80 ]] && echo "long run: $STEPS steps -- failures run roughly twice the length of successes" >> "$CTL/signals.txt"
fi
if [[ ${#PROTECT[@]} -gt 0 && -s "$CTL/changed.txt" ]]; then
  while IFS= read -r line; do
    rel="${line#* }"; rel="${rel#"${rel%%[![:space:]]*}"}"
    for g in "${PROTECT[@]}"; do
      case "$rel" in $g) echo "protected path touched: $rel" >> "$CTL/signals.txt" ;; esac
    done
  done < "$CTL/changed.txt"
fi

# ---- Publish artifacts, then report -----------------------------------------
for f in changed.txt outside.txt tools.txt actions.txt metrics.json answer.txt \
         stderr.txt branch status.before status.after head.before unstaged.diff \
         staged.diff brief.sent.md sandbox.sb signals.txt out-of-scope.txt \
         verify-before.log verify-after.log regress-before.log regress-after.log \
         verify-restored.log candidate.patch hookfiles.txt; do
  [[ -e "$CTL/$f" ]] && cp -f "$CTL/$f" "$OUT/$f" 2>/dev/null
done

BRANCH_LINE=""
[[ -s "$CTL/branch" ]] && BRANCH_LINE="  [branch: $(esc_one "$(head -1 "$CTL/branch")")]"

echo "=== swe2 run $RUN_ID ==="
echo "status:     $STATUS"
echo "model:      $MODEL (mode: $MODE, sandbox: $([[ $SANDBOX == 1 ]] && echo on || echo OFF))"
echo "workspace:  $WORKSPACE$BRANCH_LINE"
[[ -n "$SESSION_ID" ]] && echo "session_id: $SESSION_ID   (resume: --resume $SESSION_ID)"
echo "artifacts:  $OUT   (elapsed: ${ELAPSED}s)"
[[ -n "$TIMED_OUT" ]] && echo "!! TIMED OUT after ${TIMEOUT}s and was killed -- any work below is PARTIAL !!"
[[ "${ORPHANS:-0}" -gt 0 ]] && echo "!! $ORPHANS process(es) survived the kill; measurements may be incomplete !!"
if [[ "$IS_GIT" == "1" && -s "$CTL/status.before" ]]; then
  echo "note:       the worktree was ALREADY dirty before this run"
  echo "            ($(wc -l < "$CTL/status.before" | tr -d ' ') pre-existing entries; changes below are this run's)"
fi
[[ -s "$CTL/metrics.json" ]] && { echo "--- metrics ---"; cat "$CTL/metrics.json"; }
[[ -s "$CTL/tools.txt"    ]] && { echo "--- tool calls ---"; head -20 "$CTL/tools.txt"; }

if [[ -n "$VERIFY" ]]; then
  echo "--- verdict ---"
  echo "$VERDICT"
  printf 'acceptance:  before exit %s -> after exit %s   (%s)\n' \
    "${VERIFY_BEFORE:-?}" "${VERIFY_AFTER:-?}" "$(esc_one "$VERIFY")"
  [[ -n "$REGRESS" ]] && printf 'regression:  before exit %s -> after exit %s   (%s)\n' \
    "${REGRESS_BEFORE:-?}" "${REGRESS_AFTER:-?}" "$(esc_one "$REGRESS")"
  [[ -n "$GAMED" ]] && printf 'with %s restored from base: exit %s\n' "${PROTECT[*]}" "$(cat "$CTL/verify-restored.rc" 2>/dev/null)"
  if [[ "${VERIFY_AFTER:-1}" -ne 0 && -s "$CTL/verify-after.log" ]]; then
    echo "--- acceptance output (tail) ---"; tail -15 "$CTL/verify-after.log" | esc_block
  fi
fi

echo "--- files touched ---   (changed* = gitignored, still reported)"
if [[ -s "$CTL/changed.txt" ]]; then
  head -50 "$CTL/changed.txt"
  n=$(wc -l < "$CTL/changed.txt" | tr -d ' ')
  [[ "$n" -gt 50 ]] && echo "  [...$n total, see $OUT/changed.txt]"
else
  echo "(none)"
fi
if [[ "$IS_GIT" == "1" ]]; then
  echo "--- diffstat ---"; git -C "$WORKSPACE" diff --stat 2>/dev/null | head -20
fi
[[ -n "$SIMPLIFIED" ]] && echo "simplify pass: $SIMPLIFIED"
if [[ -s "$CTL/out-of-scope.txt" ]]; then
  echo "--- !! CHANGED OUTSIDE DECLARED SCOPE !! ---"
  head -20 "$CTL/out-of-scope.txt"
fi
if [[ "$MAX_FILES" -gt 0 && "$N_FILES" -gt "$MAX_FILES" ]]; then
  echo "size tripwire: $N_FILES files changed (budget $MAX_FILES) -- solve rates fall off a cliff past ~3 files; consider decomposing the task"
fi
if [[ "$MAX_LINES" -gt 0 && "$N_LINES" -gt "$MAX_LINES" ]]; then
  echo "size tripwire: $N_LINES lines changed (budget $MAX_LINES) -- patches over ~100 lines resolve under 10% of the time"
fi
if [[ -s "$CTL/signals.txt" ]]; then
  echo "--- quality signals (flags, not failures) ---"
  head -10 "$CTL/signals.txt" | esc_block
fi
if [[ -s "$CTL/hookfiles.txt" ]]; then
  echo "--- !! AGENT-EXECUTABLE HOOK FILES PRESENT !! ---"
  echo "    These are loaded by the devin CLI on a subsequent dispatch. Review before"
  echo "    committing anything from this worktree."
  cat "$CTL/hookfiles.txt"
fi
if [[ "$ESCAPE_CHECKED" == "1" ]]; then
  if [[ -n "$ESCAPED" ]]; then
    echo "--- !! PATHS TOUCHED OUTSIDE WORKSPACE !! ---"; head -20 "$CTL/outside.txt"
  else
    echo "escape check: performed, no out-of-workspace paths in the trace"
  fi
else
  echo "escape check: NOT PERFORMED ($TRACE_WHY) -- out-of-workspace writes were not ruled out"
fi
[[ -s "$CTL/stderr.txt" ]] && { echo "--- stderr (tail) ---"; tail -20 "$CTL/stderr.txt" | esc_block; }
if [[ -s "$CTL/answer.txt" ]] && grep -q '^RESULT[[:space:]]*$' "$CTL/answer.txt" 2>/dev/null; then
  echo "--- agent result (self-reported, VERIFY IT) ---"
  # The LAST sentinel, not the first: an agent that narrates "I'll end with a
  # RESULT block" (or emits the word alone early) would otherwise have its prose
  # captured from there to EOF and printed as the result.
  awk '/^RESULT[[:space:]]*$/{n=NR} END{print n+0}' "$CTL/answer.txt" > "$CTL/.rl"
  tail -n "+$(( $(cat "$CTL/.rl") + 1 ))" "$CTL/answer.txt" | head -20 | esc_block
  echo "--- full answer: $OUT/answer.txt ---"
else
  echo "--- agent answer (no RESULT block returned) ---"
  [[ -s "$CTL/answer.txt" ]] && { head -c 4000 "$CTL/answer.txt" | esc_block; }
fi
exit $STATUS
