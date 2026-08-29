#!/usr/bin/env bash
# PreToolUse hook for Agent / SendMessage. Belt-and-suspenders on top of
# subagent-context-start.sh (SubagentStart) and subagent-context-refresh.sh
# (PostToolUse, periodic): appends ONLY subagent-role-note.md — the "you are
# a subagent" identity note — to the outgoing prompt (Agent) or message
# (SendMessage) field. NOT the full style/coordinator/lily bundle; that's
# already the other two hooks' job. This one exists because the identity
# note is the single load-bearing fact whose loss breaks everything else (a
# subagent that forgets it's a subagent confabulates being top-level), so it
# gets a THIRD, structurally different delivery path — spliced directly into
# the spawn/resume prompt text itself, not delivered as a system-reminder
# additionalContext block that can (and per owner's own measurement, does)
# drop out of context well before a long run ends.
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
# byte offset right before the CLOSING '"' of the target field's value inside
# the ORIGINAL raw tool_input text, and insert the (separately, carefully
# escaped) role-note text there. Every other byte of tool_input — every
# other field, all original escaping — passes through untouched, because it
# is never parsed or reconstructed, just echoed. See lib/splice-field.awk for
# the splice itself and why its raw-text key matching is safe here.
#
# SendMessage is covered, not just Agent: a resumed (previously-finished)
# agent does not re-fire SubagentStart, so a message sent to it via
# SendMessage is the only remaining moment to re-assert identity for that
# agent — the periodic PostToolUse refresh only fires on the resumed agent's
# OWN subsequent tool calls, which happen after it's already read (or
# mis-read) the incoming message.
#
# Inject-always, not inject-once-per-recipient: see the now-deleted
# inject-subagent-context-agent.sh's reasoning, preserved here — tracking
# "already injected for recipient X" is state that drifts from reality
# (recipient restarts, name reuse, cross-session sends this hook can't see).
# Redundant injection costs a few tokens; a wrong dedup decision costs a
# subagent silently forgetting what it is.

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
role_note_file="$dir/subagent-role-note.md"

if [ ! -f "$role_note_file" ]; then
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

# ── escape subagent-role-note.md content for splicing into a JSON string ──
# Same escaper subagent-context-start.sh's escape_file() / deny() use:
# backslash, quote, tab, CR handled explicitly; source lines joined with a
# literal \n (JSON's own newline escape), trailing \n trimmed.
escaped_note=$(awk '
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "\\r")
        printf "%s\\n", $0
    }
' "$role_note_file" | sed '$ s/\\n$//')

inject="\\n\\n${escaped_note}"

# ── splice: insert right before the closing quote of the field's value
# (i.e. append after the original content, separated by a blank line), leave
# every other byte of tool_input untouched. Empty output means the field
# wasn't found as a top-level string value — no-op. ─────────────────────────
spliced=$(FIELD="$field" INJECT="$inject" awk -f "$dir/lib/splice-field.awk" <<< "$rest")

if [ -z "$spliced" ]; then
  exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s}}\n' "$spliced"
