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
# Re-emits style-rules.md, subagent-coordinator-note.md, the lily persona,
# AND subagent-role-note.md (the last on its own separate, higher-frequency
# gate — see below). The coordinator-note counters the hardcoded harness
# guidance that a coordinator's relayed message is never the user's consent —
# that guidance is standing, effectively re-asserted every turn, so a spawn-only
# note gets outweighed over a long run and the subagent drifts back to
# treating relayed task-direction as suspect. Folding the note into this
# periodic refresh matches its cadence to the cadence of the guidance it's
# countering.
#
# The lily persona (.claude/agents/lily.md's body, frontmatter stripped)
# drifts back the same way over a long run — it's only asserted once, at
# spawn, same as the coordinator-note used to be — so it rides the same
# periodic refresh for the same reason. This fires for every subagent
# regardless of subagent_type, not just ones spawned as "lily" — intentional
# per owner direction (persona-reinforcement across the lily ecosystem), not
# an oversight.
#
# subagent-role-note.md (the SubagentStart "you are a subagent, here's how
# to behave" identity note) rides a SEPARATE, higher-frequency gate — RANDOM
# % 3 == 0, ~33% of tool-call rounds, checked independently of the ~12.5%
# main gate below. It's the load-bearing one: its absence is what causes a
# subagent to forget it's a subagent and confabulate being top-level, and
# it's short, so re-asserting it more often costs little and closes the gap
# where the identity lapses for a long stretch between main-gate hits on a
# long run. Structured as two independent RANDOM draws rather than one
# shared gate so the role note can fire even on rounds where the bigger
# style/coordinator/lily payload doesn't — a single gate would floor the
# role note's refresh rate at the same 1-in-8 as everything else, which is
# exactly the gap this is meant to close.
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
coordinator_note_file="$dir/subagent-coordinator-note.md"
# lily.md lives under .claude/agents/, not tooling/claude-hooks/ — same
# repo-root-relative path used by block-mainsession-exploration.sh to locate
# an agent definition file from this dir.
lily_file="$dir/../../.claude/agents/lily.md"
role_note_file="$dir/subagent-role-note.md"

input=$(head -c $((1024 * 1024)))

# shellcheck source=lib/agent-id.sh
source "$dir/lib/agent-id.sh"

# Main session — never refresh here, inject-style-rules.sh already covers it.
if ! is_subagent "$input"; then
    exit 0
fi

# Two independent stateless coin flips — see header for the rate choices.
# Neither exits early here: a miss on one must not suppress the other, so
# both gates get evaluated and the payload is built from whichever hit,
# with the single combined exit deferred to the "nothing to inject" check
# below.
main_hit=0
(( RANDOM % 8 == 0 )) && main_hit=1
role_hit=0
(( RANDOM % 3 == 0 )) && role_hit=1

if (( ! main_hit && ! role_hit )); then
    exit 0
fi

escape_stdin() {
    awk '
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            printf "%s\\n", $0
        }
    ' | sed '$ s/\\n$//'
}

escape_file() {
    escape_stdin < "$1"
}

# lily.md's frontmatter (name/description, between the first two lone "---"
# fences) is agent-registration metadata, not persona text — strip it before
# injecting, same fence-counting approach as
# block-mainsession-exploration.sh's frontmatter read, inverted to keep the
# body instead of the fenced block.
lily_body_escaped() {
    awk '
        /^---[[:space:]]*$/ { fence++; next }
        fence >= 2
    ' "$1" | escape_stdin
}

inject=""

if (( main_hit )); then
    for f in "$style_file" "$coordinator_note_file"; do
        if [ -f "$f" ]; then
            if [ -n "$inject" ]; then
                inject="${inject}\\n\\n"
            fi
            inject="${inject}$(escape_file "$f")"
        fi
    done

    if [ -f "$lily_file" ]; then
        lily_escaped="$(lily_body_escaped "$lily_file")"
        if [ -n "$lily_escaped" ]; then
            if [ -n "$inject" ]; then
                inject="${inject}\\n\\n"
            fi
            inject="${inject}<lily-persona>\\n${lily_escaped}\\n</lily-persona>"
        fi
    fi
fi

# subagent-role-note.md already self-wraps in <subagent-note> the same way
# style-rules.md and subagent-coordinator-note.md do, so it needs no added
# tag here — same as those two. Gated on its own higher-frequency role_hit,
# independent of main_hit, per the header note above.
if (( role_hit )) && [ -f "$role_note_file" ]; then
    if [ -n "$inject" ]; then
        inject="${inject}\\n\\n"
    fi
    inject="${inject}$(escape_file "$role_note_file")"
fi

# Nothing to inject — no context files present.
if [ -z "$inject" ]; then
    exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$inject"
