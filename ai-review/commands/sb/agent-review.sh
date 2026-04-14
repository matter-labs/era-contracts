#!/bin/sh
#
# Usage:
#   ./run-agent.sh <claude|codex> <branch> [--yolo] [review-report]
#
# What it does:
#   - Reads ./PROMPT.md
#   - Replaces <BRANCH-NAME> and <REVIEW-REPORT>
#   - Runs either claude or codex with the generated prompt
#
# Notes:
#   - review-report defaults to agent-review.md
#   - --yolo enables unrestricted execution mode

set -eu

usage() {
  cat <<'EOF'
Usage:
  ./run-agent.sh <claude|codex> <branch> [--yolo] [review-report]

Examples:
  ./run-agent.sh claude feature/my-branch
  ./run-agent.sh codex feature/my-branch --yolo
  ./run-agent.sh claude feature/my-branch review.md
  ./run-agent.sh codex feature/my-branch --yolo review.md
EOF
}

err() {
  printf '%s\n' "Error: $*" >&2
  exit 1
}

[ $# -ge 2 ] || { usage >&2; exit 1; }
[ $# -le 4 ] || { usage >&2; exit 1; }

TYPE=$1
BRANCH=$2
YOLO=0
REVIEW_REPORT="agent-review.md"

case "$TYPE" in
  claude|codex) ;;
  *)
    err "type must be 'claude' or 'codex'"
    ;;
esac

case $# in
  2)
    ;;
  3)
    if [ "$3" = "--yolo" ]; then
      YOLO=1
    else
      REVIEW_REPORT=$3
    fi
    ;;
  4)
    [ "$3" = "--yolo" ] || err "when 4 arguments are provided, the 3rd must be --yolo"
    YOLO=1
    REVIEW_REPORT=$4
    ;;
esac

[ -f "./PROMPT.md" ] || err "./PROMPT.md not found"

PROMPT=$(
  awk -v branch="$BRANCH" -v report="$REVIEW_REPORT" '
    {
      gsub(/<BRANCH-NAME>/, branch)
      gsub(/<REVIEW-REPORT>/, report)
      print
    }
  ' ./PROMPT.md
)

if ! command -v "$TYPE" >/dev/null 2>&1; then
  err "'$TYPE' command not found in PATH"
fi

case "$TYPE" in
  claude)
    if [ "$YOLO" -eq 1 ]; then
      exec claude \
        -p \
        --model opus \
        --effort high \
        --permission-mode bypassPermissions \
        "$PROMPT"
    else
      exec claude \
        -p \
        --model opus \
        --effort high \
        "$PROMPT"
    fi
    ;;

  codex)
    if [ "$YOLO" -eq 1 ]; then
      exec codex exec \
        --model gpt-5.4 \
        -c 'model_reasoning_effort="high"' \
        --yolo \
        "$PROMPT"
    else
      exec codex exec \
        --model gpt-5.4 \
        -c 'model_reasoning_effort="high"' \
        "$PROMPT"
    fi
    ;;
esac