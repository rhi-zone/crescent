#!/usr/bin/env bash
# PreToolUse hook for Bash. Denies `find` invocations rooted at a handful of
# known-enormous filesystem paths, which reliably eat the full bash timeout
# walking a tree with tens of thousands of entries before ever reaching the
# caller's actual target.
#
# This was reproduced directly, not guessed: `find /` and near-root variants
# (`find ~/.cargo /root`, `find / -maxdepth 8`) hung a subagent's Bash call
# for the full 2-minute timeout. Measuring the roots below in this kind of
# NixOS-from-flake dev environment:
#   /            -> recurses straight into /nix/store
#   /nix/store   -> 70k+ *top-level* entries (flat layout) — even
#                   `-maxdepth 1` doesn't help, the breadth explosion is
#                   already at depth 1
#   /proc, /sys  -> virtual filesystems; recursing them is well-known-bad
#                   independent of size (self-referential entries, odd
#                   permissions, unbounded/misleading sizes)
#   /root, /usr, /home (bare), $HOME/~ (bare) -> broad enough in practice
#                   to be the same failure mode, and never what a scoped
#                   "find this file in my project" call actually wants
#
# Critically, -maxdepth does NOT reliably save these — `find / -maxdepth 8`
# was one of the reproduced hangs, because the huge directory is only 1-2
# levels down. So unlike a generic "is it bounded" check, this hook does not
# treat -maxdepth as sufficient mitigation for these specific roots: it
# blocks on the root path alone and asks for a narrower one instead.
#
# Deliberately narrow in scope: this only targets the reproduced hang
# (unbounded walk of an enormous tree). It does not attempt to police
# `-exec`, permissions, or other find-safety concerns — those are separate,
# unrelated risk categories and belong in their own hook if ever needed.
#
# Jq-free by design, matching block-blocking-bash.sh: the harness doesn't
# always have jq on PATH. Same sed-based extraction of tool_input.command.

set -euo pipefail

input=$(cat)

cmd=$(printf '%s' "$input" \
  | tr '\n' ' ' \
  | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"((\\\\|\\"|[^"])*)".*/\1/p' \
  | head -1)

# Strip quoted regions and heredoc bodies so a `find` mentioned inside a
# string literal (e.g. `echo "find / is dangerous"`) doesn't trip this.
scan=$(printf '%s' "$cmd" \
  | sed -E "s/<<-?[[:space:]]*'?[A-Za-z_][A-Za-z0-9_]*'?.*$//" \
  | sed -E 's/"[^"]*"//g' \
  | sed -E "s/'[^']*'//g")

home="${HOME:-}"

is_huge_root() {
  local p="$1"
  if [[ "$p" != "/" ]]; then p="${p%/}"; fi
  case "$p" in
    "/"|"/nix"|"/nix/store"|"/usr"|"/proc"|"/sys"|"/root"|"/home") return 0 ;;
  esac
  if [[ "$p" == '$HOME' || "$p" == '${HOME}' || "$p" == "~" ]]; then return 0; fi
  if [[ -n "$home" && "$p" == "$home" ]]; then return 0; fi
  return 1
}

reason=""

# Every occurrence of the word "find", plus everything up to the next
# command separator (; & | ) or closing paren — catches top-level `find`
# calls as well as ones inside $(...) / `...` substitutions, without
# requiring a full parse.
while IFS= read -r invocation; do
  [[ -z "$invocation" ]] && continue
  rest="${invocation#find}"
  for tok in $rest; do
    case "$tok" in
      -*|"("|"!") break ;;
    esac
    if is_huge_root "$tok"; then
      reason="find rooted at '$tok'"
      break 2
    fi
  done
done < <(printf '%s' "$scan" | grep -oE '\bfind\b[^;&|)]*' || true)

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Refused: %s — that path is a huge/flat or virtual tree in this kind of environment and reliably exhausts the bash timeout walking it (e.g. /nix/store alone has 70k+ entries at depth 1; -maxdepth does not save it here). Narrow the root to the actual directory you care about (e.g. find ./src -name \\"*.rs\\"), or use rg --files / fd for a name search, or pass run_in_background:true to the Bash tool if you genuinely need this to run to completion unattended."}}\n' "$reason"
fi
