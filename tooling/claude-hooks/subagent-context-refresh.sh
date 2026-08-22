#!/usr/bin/env bash
# PostToolUse hook (matcher ""). Fires on every tool call, both in the main
# session and inside a subagent's own tool-calling loop — gated here to only
# ever act for subagents (top-level agent_id in the hook JSON), since the
# main session already has its own style refresh via UserPromptSubmit
# (inject-style-rules.sh).
#
# Probabilistic gate, not a per-agent turn counter: RANDOM % 8 == 0, ~12.5%
# of a subagent's own tool-call rounds. Mirrors inject-style-rules.sh's
# stateless-coin-flip reasoning (see that file's header) — a real counter
# needs a state file keyed per-agent, with all the concurrent-subagent and
# cleanup problems that file already declined to take on for the main
# session. Picked a lower rate than the main session's 1-in-5: a subagent's
# own tool-calling loop fires PostToolUse on EVERY tool call, which is a much
# tighter cadence than the main session's UserPromptSubmit (one per user/
# coordinator turn) — 1-in-5 at that cadence would restack the style guide
# into context multiple times over a handful of tool calls. 1-in-8 keeps
# refreshes periodic without being redundant on short subagent runs.
#
# Replaces the old PreToolUse(SendMessage)-splice periodic-refresh half of
# inject-subagent-context-agent.sh: that fired 100% of the time a message was
# sent TO a running agent (rare, so 100% was cheap). This decouples refresh
# from "did a message arrive" entirely and ties it to the subagent's own
# activity instead, per the owner's build direction — a subagent's context
# can go stale just from working for a while, not only from receiving a new
# message.
#
# additionalContext delivery confirmed real for PostToolUse the same way as
# SubagentStart (see subagent-context-start.sh's header) — tested end-to-end
# against the installed Claude Code version, not assumed from docs.
#
# Jq-free (matches this dir's convention).

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
style_file="$dir/style-rules.md"

if [ ! -f "$style_file" ]; then
    exit 0
fi

input=$(head -c $((1024 * 1024)))

# shellcheck source=lib/agent-id.sh
source "$dir/lib/agent-id.sh"

# Main session — never refresh here, inject-style-rules.sh already covers it.
if ! is_subagent "$input"; then
    exit 0
fi

# Stateless coin flip — see header for the rate choice.
if (( RANDOM % 8 != 0 )); then
    exit 0
fi

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

inject="$(escape_file "$style_file")"

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$inject"
