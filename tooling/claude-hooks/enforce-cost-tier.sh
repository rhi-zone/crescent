#!/usr/bin/env bash
# PreToolUse hook — cost-tier enforcement at ALL depths (main session AND subagents).
#
# Every Agent spawn must include an explicit model param. No exceptions.
# Opus: self-attestation via [i swear this needs opus reasoning] (no user approval).
# Fable: user-approved via [frontier-approved].
# Haiku/sonnet: allowed with just the model param.
# Workflow: disabled unconditionally (unpredictable cost amplification).
#
# No python, jq, node, perl, ruby, nix-shell, or compiled binaries.

set -euo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
input=$(head -c $((1024 * 1024)))

# ── denial helper ─────────────────────────────────────────────────────────────
deny() {
    local reason="$1"
    local escaped
    escaped=$(printf '%s' "$reason" | awk '
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            printf "%s\\n", $0
        }
    ' | sed '$ s/\\n$//')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$escaped"
    exit 0
}

# ── split on "tool_input" ─────────────────────────────────────────────────────
prefix="${input%%\"tool_input\"*}"
rest="${input#*\"tool_input\":}"

# ── extract tool_name (only from prefix) ─────────────────────────────────────
tool_name=$(printf '%s' "$prefix" | grep -oE '"tool_name"\s*:\s*"[^"]*"' | head -1 | grep -oE '"[^"]*"$' | tr -d '"' || true)
if [[ -z "$tool_name" ]]; then
    exit 0
fi

# ── Workflow: disabled unconditionally ────────────────────────────────────────
if [[ "$tool_name" == "Workflow" ]]; then
    deny "sorry :c ur not good at writing workflows so its unilaterally disabled :/ instead send agents manually"
fi

# ── Agent: cost-tier gate ─────────────────────────────────────────────────────
if [[ "$tool_name" == "Agent" ]]; then
    model_val=$(printf '%s' "$rest" | awk -v field="model" -f "$dir/lib/extract-field.awk")

    COST_MSG="name the tier explicitly! haiku for mechanical/extraction, sonnet for execution hands. opus needs [i swear this needs opus reasoning] in the prompt (self-attestation, no user approval needed). fable needs [frontier-approved] (requires explicit user approval)."

    if [[ -z "$model_val" ]]; then
        deny "$COST_MSG"
    fi

    # Classify by substring — catches full model ids (claude-opus-4-6),
    # suffixed forms (opus[1m]), bedrock-prefixed forms, etc.
    if [[ "$model_val" == *opus* ]]; then
        # opus is self-serviceable but attested: no user approval, just the tag.
        if ! printf '%s' "$rest" | grep -qF '[i swear this needs opus reasoning]'; then
            deny "opus does not require user approval, but it must be attested — include [i swear this needs opus reasoning] in the prompt!"
        fi
    elif [[ "$model_val" == *fable* ]]; then
        if ! printf '%s' "$rest" | grep -qF '[frontier-approved]'; then
            deny "fable requires user-approved cost — include [frontier-approved] in the prompt, but only if {{user}} explicitly told you it's allowed!"
        fi
    elif [[ "$model_val" == *haiku* || "$model_val" == *sonnet* ]]; then
        : # non-frontier tier, no gate needed
    else
        # Unknown tier — fail closed
        deny "$COST_MSG"
    fi
fi

exit 0
