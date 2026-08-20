#!/usr/bin/env bash
# UserPromptSubmit hook — inject short style-discipline rules on ~1-in-5 turns.
#
# Unlike inject-orchestrator-rules.sh, this fires for both main session AND
# subagents: the rules it carries (concise, no overclaiming, no banned words)
# apply to any response the harness produces, not just orchestration.
#
# Was inject-every-turn until the owner flagged it as wasteful in the same
# vein as the Agent/SendMessage over-injection fixed earlier in this file's
# history: a session that already has the rules in context doesn't need a
# fresh copy appended on every single prompt, stacking duplicates over a long
# conversation. A subagent's spawn-time context (inject-subagent-context-agent.sh,
# 100% on Agent calls) already delivers style-rules.md once at birth, so this
# hook re-injecting on every subsequent turn was pure redundancy there too.
#
# Chose a stateless coin flip ($RANDOM % 5 == 0, ~20% of turns) over a real
# per-session turn counter. A counter needs a state file keyed by session —
# this dir has ONE existing state-dir precedent (block-mainsession-exploration.sh's
# CLAUDE_HOOK_STATE_DIR, default /tmp/claude-state), but that's a debug log
# sink, not a counting pattern, and it isn't keyed per-session at all. Building
# real per-session counting would mean picking a session key, handling
# concurrent subagents sharing or not sharing that key, and cleaning up
# counter files that would otherwise accumulate forever — real state-drift
# surface for a "how often should a reminder repeat" problem that a coin flip
# solves with no state at all. If per-session exactness (guaranteed every 5th
# turn, not merely ~20% on average) ever matters enough to justify that cost,
# revisit with a real counter; until then, stateless wins on simplicity.
#
# No jq, python, or node — pure bash (matches the other hooks' pattern).

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if (( RANDOM % 5 == 0 )); then
  cat "$dir/style-rules.md"
fi
