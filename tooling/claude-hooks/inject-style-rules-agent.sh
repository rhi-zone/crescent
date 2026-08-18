#!/usr/bin/env bash
# PreToolUse hook for Agent / SendMessage. Prepends style-rules.md content to
# the outgoing prompt (Agent) or message (SendMessage) field, so subagents —
# and agents already running when SendMessage is used to talk to them — get
# the same style guide the main session gets via inject-style-rules.sh
# (UserPromptSubmit).
#
# Mechanism: PreToolUse hooks can return
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{...}}}
# to rewrite the tool_input before execution. We always emit the FULL
# tool_input object (unmodified fields included, only the target field
# changed) rather than a partial object — current docs don't state whether
# updatedInput merges or replaces, so emitting the complete object is correct
# either way.
#
# Jq-free (matches this dir's convention: the harness doesn't always have jq
# on PATH). Unlike the read-only hooks here — which extract a field with
# extract-field.awk to make an allow/deny call, where a parse miss just fails
# open — this one WRITES a new value back into the call. So instead of
# parsing tool_input into pieces and re-serializing it (real risk: mis-escape
# something and corrupt/truncate the payload), we splice: find the exact
# byte offset right after the opening '"' of the target field's value inside
# the ORIGINAL raw tool_input text, and insert the (separately, carefully
# escaped) style-guide text there. Every other byte of tool_input — every
# other field, all original escaping — passes through untouched, because it
# is never parsed or reconstructed, just echoed. See lib/splice-field.awk for
# the splice itself and why its raw-text key matching is safe here.
#
# Inject-always, not inject-once-per-recipient: SendMessage targets an
# already-running agent that (if spawned via Agent through this same hook, or
# via UserPromptSubmit for a top-level session) already got the guide once.
# Tracking "already injected for recipient X" is state, and state drifts from
# reality — a recipient can restart, a name can get reused by a different
# agent, cross-session sends don't share this hook's state at all. Redundant
# injection costs a few tokens; a wrong dedup decision costs a silently
# unstyled agent. Simplest-correct wins here.

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
style_file="$dir/style-rules.md"

if [ ! -f "$style_file" ]; then
  exit 0
fi

input=$(cat)

# ── tool_name (same split + extraction block-mainsession-exploration.sh
# uses: everything before the first "tool_input" occurrence, tool_name read
# only from that prefix) ─────────────────────────────────────────────────────
prefix="${input%%\"tool_input\"*}"

# No "tool_input" key anywhere in the payload — nothing to splice into.
if [ "$prefix" = "$input" ]; then
  exit 0
fi

tool_name=$(printf '%s' "$prefix" | grep -oE '"tool_name"\s*:\s*"[^"]*"' | head -1 | grep -oE '"[^"]*"$' | tr -d '"' || true)

case "$tool_name" in
  Agent) field=prompt ;;
  SendMessage) field=message ;;
  *) exit 0 ;;
esac

rest="${input#*\"tool_input\":}"

# ── escape style-rules.md content for splicing into a JSON string ──────────
# Same escaper block-mainsession-exploration.sh's deny() uses: backslash,
# quote, tab, CR handled explicitly; source lines joined with a literal \n
# (JSON's own newline escape), trailing \n trimmed.
escaped_style=$(awk '
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "\\r")
        printf "%s\\n", $0
    }
' "$style_file" | sed '$ s/\\n$//')

inject="${escaped_style}\\n\\n"

# ── splice: insert right after the opening quote of the field's value,
# leave every other byte of tool_input untouched. Empty output means the
# field wasn't found as a top-level string value — no-op. ──────────────────
spliced=$(FIELD="$field" INJECT="$inject" awk -f "$dir/lib/splice-field.awk" <<< "$rest")

if [ -z "$spliced" ]; then
  exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s}}\n' "$spliced"
