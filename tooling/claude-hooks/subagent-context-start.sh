#!/usr/bin/env bash
# SubagentStart hook (matcher ""). Fires once, at spawn, for every subagent —
# never for the main session, since SubagentStart only exists on the
# subagent side of the lifecycle.
#
# Emits style-rules.md + subagent-role-note.md + subagent-coordinator-note.md
# as one combined additionalContext blob via the documented
#   {"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"..."}}
# form.
#
# This supersedes the old PreToolUse(Agent)-splice approach in
# inject-subagent-context-agent.sh, whose header claimed SubagentStart does
# NOT support additionalContext at all. That claim was tested end-to-end
# against the installed Claude Code version (2.1.231) on 2026-08-22: a
# SubagentStart hook emitting this exact hookSpecificOutput form was wired in
# via a scratch settings.local.json hook, a subagent was spawned, and the
# subagent confirmed seeing the marker text as its own system-reminder block.
# The claim was wrong (or the behavior changed since it was written) — verified
# real, not assumed from docs.
#
# Jq-free (matches this dir's convention). Reuses the same control-char
# escaper block-mainsession-exploration.sh's deny() and the old
# inject-subagent-context-agent.sh's escape_file() use, extended to join
# multiple files with a blank line between them.

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
style_file="$dir/style-rules.md"
role_note_file="$dir/subagent-role-note.md"
coordinator_note_file="$dir/subagent-coordinator-note.md"

# ── escape a file's content for splicing into a JSON string value ──────────
escape_file() {
    awk '
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            printf "%s\\n", $0
        }
    ' "$1" | sed '$ s/\\n$//'
}

inject=""
for f in "$style_file" "$role_note_file" "$coordinator_note_file"; do
    if [ -f "$f" ]; then
        if [ -n "$inject" ]; then
            inject="${inject}\\n\\n"
        fi
        inject="${inject}$(escape_file "$f")"
    fi
done

# Nothing to inject — no context files present.
if [ -z "$inject" ]; then
    exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"%s"}}\n' "$inject"
