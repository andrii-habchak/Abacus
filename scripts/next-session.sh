#!/usr/bin/env bash
# Prints the hand-off prompt for a new orchestrator session (docs/NEXT.md, after the "---" line)
# and copies it to the clipboard. Start the new agent session in this repository's folder and
# paste it.
set -euo pipefail
cd "$(dirname "$0")/.."
prompt="$(awk 'found { print } /^---$/ { found = 1 }' docs/NEXT.md)"
printf '%s\n' "$prompt"
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s\n' "$prompt" | pbcopy
  echo
  echo "(Copied to the clipboard. Repository: $PWD)"
fi
