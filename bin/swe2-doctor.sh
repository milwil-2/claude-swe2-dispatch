#!/usr/bin/env bash
# Preflight for the swe2-dispatch plugin: checks every prerequisite and reports
# what is missing. Read-only -- starts no agent session and spends nothing.
set -uo pipefail

DEVIN="${DEVIN_BIN:-$HOME/.local/bin/devin}"
FAIL=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }
warn() { printf '  warn  %s\n' "$1"; }

echo "swe2-dispatch preflight"
echo

echo "Platform"
if [[ "$(uname -s)" == "Darwin" ]]; then ok "macOS ($(uname -m))"
else bad "this plugin confines writes with macOS seatbelt; $(uname -s) is unsupported (dispatch would require --no-sandbox, which runs unconfined)"; fi
if command -v sandbox-exec >/dev/null 2>&1; then ok "sandbox-exec present"
else bad "sandbox-exec not found -- confinement unavailable"; fi
echo

echo "SWE-2 agent CLI"
if [[ -x "$DEVIN" ]]; then ok "devin at $DEVIN ($("$DEVIN" --version 2>/dev/null | head -1))"
else bad "devin CLI not found at $DEVIN -- install it, or set DEVIN_BIN to its path"; fi
echo

echo "Account access"
if [[ -x "$DEVIN" ]]; then
  MODELS="$("$DEVIN" models list 2>&1)"
  if echo "$MODELS" | grep -qiE '^SWE-2 '; then
    ok "SWE-2 available$(echo "$MODELS" | grep -A4 '^SWE-2 (' | grep -oE 'Free' | head -1 | sed 's/^/ (/;s/$/ on this account)/')"
    echo "$MODELS" | grep -A4 '^SWE-2 (' | grep -oE 'swe-2-[a-z]+' | sed 's/^/        /'
  elif echo "$MODELS" | grep -qi 'auth\|login\|unauthor'; then
    bad "not authenticated -- run: devin auth login"
  elif ! echo "$MODELS" | grep -qi 'Available models'; then
    # Distinguish a failed lookup from a genuine absence -- the model list is a
    # network call and a transient failure must not be reported as "no access".
    warn "could not read the model list (transient API or network failure?); rerun to confirm"
    printf '        %s\n' "$(echo "$MODELS" | head -2)"
  else
    bad "no SWE-2 family on this account (model list read OK, SWE-2 absent)"
  fi
else warn "skipped -- devin unavailable"; fi
echo

echo "Agent rules that break non-interactive dispatch"
# devin loads ~/.config/devin/AGENTS.md (and .claude/settings.json) on every run.
# An approval-style rule there makes file edits need confirmation -- which cannot
# be given in -p mode, so the agent analyses correctly and then silently does
# nothing. This gagged 48 of 61 runs once before it was diagnosed.
RULES="${XDG_CONFIG_HOME:-$HOME/.config}/devin/AGENTS.md"
if [[ -f "$RULES" ]]; then
  if grep -qiE '(ask|approval|permission|confirm)[^.]{0,80}(before|prior to)[^.]{0,80}(writ|edit|creat|chang|modif)' "$RULES" \
     || grep -qiE '(writ|edit|creat)[^.]{0,60}(require|need)[^.]{0,40}(approval|confirmation|permission)' "$RULES"; then
    bad "$RULES appears to require approval before file edits.
              devin cannot ask in non-interactive mode, so edits will be dropped and
              dispatches will do nothing. Scope that rule so a described task authorises
              the edits it implies, or keep it and expect BLOCKED verdicts."
  else
    ok "$RULES has no approval-before-edit rule"
  fi
else
  ok "no user AGENTS.md (nothing to gag edits)"
fi
echo

echo "Supporting tools"
command -v jq   >/dev/null 2>&1 && ok "jq"   || bad "jq not found -- the run report degrades badly without it"
command -v git  >/dev/null 2>&1 && ok "git"  || bad "git not found"
echo

if [[ "$FAIL" == "0" ]]; then
  echo "Ready. Dispatch into the root of a linked git worktree:"
  echo "  swe2-dispatch.sh --workspace <worktree> --brief <file> --out <dir>"
else
  echo "Not ready -- resolve the FAIL lines above."
fi
exit $FAIL
