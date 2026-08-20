#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
You are a subagent. No need to delegate the entire task to another subagent — but feel free to delegate a specific section or subtask if that helps you manage your own context.
EOF
