#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/review-prompt.md"

usage() {
    cat <<EOF
Usage:
  $0 --codex  <branch-name> <review-report> [tool args...]
  $0 --claude <branch-name> <review-report> [tool args...]

Examples:
  $0 --codex main review.md --full-auto
  $0 --claude develop reports/review.md --model sonnet
EOF
    exit 1
}

[[ $# -ge 3 ]] || usage

case "$1" in
    --codex)
        TOOL="codex"
        ;;
    --claude)
        TOOL="claude"
        ;;
    *)
        echo "Error: you must specify either --codex or --claude."
        usage
        ;;
esac

shift

BRANCH_NAME="$1"
REVIEW_REPORT="$2"
shift 2

PROMPT="$(
    sed \
        -e "s|<BRANCH-NAME>|${BRANCH_NAME}|g" \
        -e "s|<REVIEW-REPORT>|${REVIEW_REPORT}|g" \
        "$PROMPT_FILE"
)"

if [[ "$TOOL" == "codex" ]]; then
    exec codex exec "$@" <<<"$PROMPT"
else
    exec claude -p "$PROMPT" "$@"
fi
