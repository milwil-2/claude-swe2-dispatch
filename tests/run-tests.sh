#!/usr/bin/env bash
# Regression suite for swe2-dispatch.
#
# Every case here corresponds to a defect found by an independent reviewer and
# fixed. They exist so a later "improvement" cannot silently reopen one -- which
# is precisely what happened between review rounds 1 and 2.
#
# Uses stub agents via DEVIN_BIN: no real SWE-2 dispatch, no network, no cost.
#
#   tests/run-tests.sh            run all
#   tests/run-tests.sh sandbox    run cases whose name matches 'sandbox'
#
# Exit 0 if all pass.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/../bin/swe2-dispatch.sh"
FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
LAB="$(mktemp -d "${TMPDIR:-/tmp}/swe2-tests.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT INT TERM

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

ok()   { PASS=$((PASS+1)); green "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }

want() {  # want <name> <expect-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2" ;; esac
}
want_not() {
  case "$3" in *"$2"*) bad "$1" "should NOT contain: $2" ;; *) ok "$1" ;; esac
}
match() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

# ---- fixtures ---------------------------------------------------------------
new_repo() {  # new_repo <name> -> echoes primary checkout path
  local n="$LAB/$1"
  mkdir -p "$n" && cd "$n" || return 1
  git init -q .
  printf 'def div(a, b):\n    return a / b\n' > m.py
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  echo "$n"
}
new_worktree() {  # new_worktree <primary> <name> -> echoes linked worktree path
  git -C "$1" worktree add -q "$LAB/$2" -b "t/$2" 2>/dev/null
  echo "$LAB/$2"
}
stub() {  # stub <name> <body> -> echoes path to an executable stub agent
  local f="$LAB/stub-$1.sh"
  { echo '#!/bin/bash'; echo 'for a in "$@"; do case "$a" in */export.json) EXPORT="$a";; esac; done'; cat; } > "$f"
  chmod +x "$f"; echo "$f"
}

BRIEF="$LAB/brief.md"; echo "do the thing" > "$BRIEF"
[[ -x "$DISPATCH" ]] || { red "dispatch script not executable: $DISPATCH"; exit 1; }

echo "swe2-dispatch regression suite"
echo

# ============================ GUARD ==========================================
echo "Worktree guard"
MAIN="$(new_repo main)"; WT="$(new_worktree "$MAIN" wt)"

if match guard/primary-checkout; then
  out="$("$DISPATCH" --workspace "$MAIN" --brief "$BRIEF" 2>&1)"
  want "guard/primary-checkout refused" "not a linked git worktree" "$out"
fi

if match guard/subdirectory; then
  mkdir -p "$WT/sub"
  out="$("$DISPATCH" --workspace "$WT/sub" --brief "$BRIEF" 2>&1)"
  want "guard/subdirectory refused" "worktree ROOT" "$out"
fi

if match guard/non-git; then
  mkdir -p "$LAB/plain"
  out="$("$DISPATCH" --workspace "$LAB/plain" --brief "$BRIEF" 2>&1)"
  want "guard/non-git refused without --scratch" "not a git worktree" "$out"
fi

if match guard/submodule; then
  SMSRC="$(new_repo smsrc)"
  ( cd "$MAIN" && git -c protocol.file.allow=always submodule add -q "$SMSRC" sm 2>/dev/null \
      && git -c user.email=t@t -c user.name=t commit -qm sub 2>/dev/null ) >/dev/null 2>&1
  if [[ -d "$MAIN/sm" ]]; then
    out="$("$DISPATCH" --workspace "$MAIN/sm" --brief "$BRIEF" 2>&1)"
    want "guard/submodule refused (its git dir is complete and committable)" "not a linked git worktree" "$out"
  else
    skip "guard/submodule refused" "submodule fixture unavailable"
  fi
fi

if match guard/planted-gitfile; then
  mkdir -p "$LAB/fake"; echo "gitdir: $MAIN/.git" > "$LAB/fake/.git"
  out="$("$DISPATCH" --workspace "$LAB/fake" --brief "$BRIEF" 2>&1)"
  want "guard/planted .git file refused" "not a linked git worktree" "$out"
fi

if match guard/env-bypass; then
  out="$(GIT_DIR="$MAIN/.git/worktrees/wt" GIT_WORK_TREE="$MAIN" \
         "$DISPATCH" --workspace "$MAIN" --brief "$BRIEF" 2>&1)"
  want "guard/GIT_DIR env bypass refused" "not a linked git worktree" "$out"
fi

if match guard/accepts-linked; then
  out="$(DEVIN_BIN=/usr/bin/true "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o1" 2>&1)"
  want "guard/genuine linked worktree accepted" "=== swe2 run" "$out"
fi

# ============================ ARGUMENTS ======================================
echo
echo "Argument handling"

if match args/mode-allowlist; then
  for m in dangerous DANGEROUS bogus; do
    out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --mode "$m" 2>&1)"
    want "args/--mode $m refused" "--mode must be one of" "$out"
  done
fi

if match args/missing-value; then
  out="$("$DISPATCH" --workspace 2>&1)"; rc=$?
  want "args/missing option value message" "requires a value" "$out"
  [[ $rc -eq 2 ]] && ok "args/missing option value exits 2" || bad "args/missing option value exits 2" "got $rc"
fi

if match args/out-inside-workspace; then
  out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$WT/runs" 2>&1)"
  want "args/--out inside workspace refused" "must not be inside the workspace" "$out"
fi

if match args/allow-write-injection; then
  inj='foo")(subpath "/Users'
  mkdir -p "$LAB/$inj" 2>/dev/null
  out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --allow-write "$LAB/$inj" 2>&1)"
  want "args/--allow-write injection (existing path) refused" "cannot be sandboxed safely" "$out"
  out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --allow-write '/nope")(subpath "/Users' 2>&1)"
  want "args/--allow-write injection (nonexistent path) refused" "cannot be sandboxed safely" "$out"
fi

# ============================ CHANGE DETECTION ===============================
echo
echo "Change detection (must survive a hostile agent)"

if match detect/backdate-and-gitignore; then
  S="$(stub evil <<'EOS'
echo "print('pwned')" > backdoor.py
printf 'backdoor.py\n.gitignore\n' > .gitignore
sed -i '' 's|return a / b|return a * b|' m.py 2>/dev/null
git update-index --assume-unchanged m.py 2>/dev/null
touch -t 200001010000 backdoor.py .gitignore m.py
echo "All done, nothing to report."
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o2" 2>&1)"
  want "detect/planted file survives backdating + self-ignoring .gitignore" "backdoor.py" "$out"
  want "detect/.gitignore itself reported"                                  ".gitignore"  "$out"
  want "detect/edited tracked file survives backdating"                     "m.py"        "$out"
  want_not "detect/does not claim a clean tree"                             "(none)"      "$out"
  ( cd "$WT" && git checkout -q -- . 2>/dev/null; rm -f backdoor.py .gitignore )
fi

if match detect/deletion; then
  S="$(stub del <<'EOS'
rm -f m.py
echo done
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o3" 2>&1)"
  want "detect/deletion reported" "[DELETED]" "$out"
  ( cd "$WT" && git checkout -q -- . 2>/dev/null )
fi

if match detect/clean-run; then
  S="$(stub noop <<'EOS'
echo "did nothing"
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o4" 2>&1)"
  want "detect/genuinely clean run reports (none)" "(none)" "$out"
fi

# ============================ SANDBOX ========================================
echo
echo "Sandbox confinement"

if match sandbox/profile; then
  DEVIN_BIN=/usr/bin/true "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o5" >/dev/null 2>&1
  PROF="$LAB/o5/sandbox.sb"
  if [[ ! -s "$PROF" ]]; then
    bad "sandbox/profile generated" "no sandbox.sb at $PROF"
  else
    ok "sandbox/profile generated"
    # $OUT legitimately lives under $TMPDIR, so the string appears; what must be
    # absent is the blanket regex grant over the whole per-user temp tree.
    want_not "sandbox/does not grant the whole temp tree" 'regex #"^/private/var/folders/"' "$(cat "$PROF")"
    want_not "sandbox/does not grant ~/.cache"            "/.cache"               "$(cat "$PROF")"
    want_not "sandbox/does not grant a writable git dir"  "worktrees/"            "$(cat "$PROF")"

    probe() { sandbox-exec -f "$PROF" /bin/sh -c "$1" >/dev/null 2>&1 && echo WROTE || echo BLOCKED; }
    [[ "$(probe "echo x > '$WT/inside.txt'")"        == WROTE   ]] && ok   "sandbox/workspace writable"        || bad "sandbox/workspace writable"
    [[ "$(probe "echo x > \"\$HOME/.swe2-test\"")"   == BLOCKED ]] && ok   "sandbox/\$HOME blocked"            || bad "sandbox/\$HOME blocked"
    [[ "$(probe "mktemp -d")"                        == BLOCKED ]] && ok   "sandbox/temp root blocked"         || bad "sandbox/temp root blocked"
    [[ "$(probe "echo x > '$MAIN/m.py'")"            == BLOCKED ]] && ok   "sandbox/primary checkout blocked"  || bad "sandbox/primary checkout blocked"
    [[ "$(probe "cd '$WT' && git add -A")"           == BLOCKED ]] && ok   "sandbox/git add blocked"           || bad "sandbox/git add blocked"
    [[ "$(probe "cd '$WT' && git update-index --assume-unchanged m.py")" == BLOCKED ]] \
      && ok "sandbox/update-index --assume-unchanged blocked (would hide sabotage from git diff)" \
      || bad "sandbox/update-index --assume-unchanged blocked"
    [[ "$(probe "cd '$WT' && git status --porcelain")" == WROTE ]] && ok "sandbox/read-only git still works" \
      || bad "sandbox/read-only git still works" "read-only git must keep working without a writable git dir"
    rm -f "$WT/inside.txt" "$HOME/.swe2-test"
  fi
fi

# ============================ ESCAPE REPORTING ===============================
echo
echo "Escape-check reporting (silence must never read as a pass)"

if match escape/traversal; then
  S="$(stub trav <<EOS
cat > "\$EXPORT" <<JSON
{"session_id":"t","steps":[{"tool_calls":[{"function_name":"edit","arguments":{"file_path":"$WT/../../../etc/shadow"}}]}],"final_metrics":{}}
JSON
echo done
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o6" 2>&1)"
  want "escape/upward traversal flagged" "PATHS TOUCHED OUTSIDE WORKSPACE" "$out"
fi

if match escape/no-trace; then
  S="$(stub notrace <<'EOS'
echo "no export written"
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o7" 2>&1)"
  want "escape/missing trace stated explicitly" "NOT PERFORMED" "$out"
fi

if match escape/clean-trace; then
  S="$(stub cleantrace <<EOS
cat > "\$EXPORT" <<JSON
{"session_id":"t","steps":[{"tool_calls":[{"function_name":"edit","arguments":{"file_path":"$WT/m.py"}}]}],"final_metrics":{}}
JSON
echo done
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o8" 2>&1)"
  want     "escape/in-workspace path not flagged" "escape check: performed" "$out"
  want_not "escape/no false alarm on normal edit" "PATHS TOUCHED OUTSIDE"   "$out"
fi

# ============================ STALE ARTIFACTS ================================
echo
echo "Artifact hygiene"

if match stale/reused-out; then
  S="$(stub stale <<'EOS'
echo "second run"
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o6" 2>&1)"
  want_not "stale/previous run's escape report not reused" "PATHS TOUCHED OUTSIDE WORKSPACE" "$out"
fi

# ============================ ORCHESTRATION SAFETY ===========================
echo
echo "Orchestration safety"

if match orch/timeout; then
  S="$(stub hang <<'EOS'
sleep 120
EOS
)"
  start=$(date '+%s')
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/t1" --timeout 3 2>&1)"
  elapsed=$(( $(date '+%s') - start ))
  want "orch/runaway agent is killed at the deadline" "TIMED OUT" "$out"
  [[ "$elapsed" -lt 60 ]] && ok "orch/timeout actually bounds wall clock (${elapsed}s)" \
                          || bad "orch/timeout actually bounds wall clock" "took ${elapsed}s"
fi

if match orch/timeout-validation; then
  out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --timeout abc 2>&1)"
  want "orch/--timeout rejects non-numeric" "whole number of seconds" "$out"
  out="$("$DISPATCH" --workspace "$WT" --brief "$BRIEF" --timeout 0 2>&1)"
  want "orch/--timeout rejects zero" "greater than zero" "$out"
fi

if match orch/concurrency; then
  S="$(stub slow <<'EOS'
sleep 8
EOS
)"
  DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/c1" >/dev/null 2>&1 &
  first=$!
  sleep 2
  out="$(DEVIN_BIN=/usr/bin/true "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/c2" 2>&1)"
  want "orch/second dispatch into the same worktree is refused" "already running in this worktree" "$out"
  wait $first 2>/dev/null
  out="$(DEVIN_BIN=/usr/bin/true "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/c3" 2>&1)"
  want "orch/lock is released when the run finishes" "=== swe2 run" "$out"
fi

if match orch/dirty-tree; then
  echo "pre-existing" >> "$WT/m.py"
  S="$(stub touchy <<'EOS'
echo "x" > newfile.txt
echo done
EOS
)"
  out="$(DEVIN_BIN="$S" "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/d1" 2>&1)"
  want "orch/pre-existing dirt is disclosed" "ALREADY dirty" "$out"
  ( cd "$WT" && git checkout -q -- . 2>/dev/null; rm -f newfile.txt )
fi

# ============================ SHELL COMPATIBILITY ============================
echo
echo "Shell compatibility"

if match shell/bash32; then
  if [[ -x /bin/bash ]]; then
    /bin/bash -n "$DISPATCH" 2>/dev/null && ok "shell/parses under $(/bin/bash --version | head -1 | sed 's/.*version //;s/ .*//')" \
      || bad "shell/parses under stock /bin/bash"
    out="$(DEVIN_BIN=/usr/bin/true /bin/bash "$DISPATCH" --workspace "$WT" --brief "$BRIEF" --out "$LAB/o9" --no-sandbox 2>&1)"
    want_not "shell/--no-sandbox has no unbound-variable abort under bash 3.2" "unbound variable" "$out"
  else
    skip "shell/bash32" "/bin/bash not present"
  fi
fi

echo
printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
