#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  ./run-agent.sh <claude|codex> <branch> [--yolo]

Examples:
  ./run-agent.sh claude feature/my-branch
  ./run-agent.sh codex feature/my-branch --yolo
EOF
}

err() {
  printf '%s\n' "Error: $*" >&2
  exit 1
}

# Validate args
[ $# -ge 2 ] || { usage >&2; exit 1; }
[ $# -le 3 ] || { usage >&2; exit 1; }

TYPE=$1
BRANCH=$2
YOLO=0

if [ $# -eq 3 ]; then
  [ "$3" = "--yolo" ] || err "unknown third argument: $3"
  YOLO=1
fi

case "$TYPE" in
  claude|codex) ;;
  *)
    err "type must be 'claude' or 'codex'"
    ;;
esac

[ -f "./PROMPT.md" ] || err "./PROMPT.md not found"

# Read prompt file and substitute all occurrences of <BRANCH-NAME>
# Using awk here keeps it POSIX-sh compatible across Linux/macOS.
PROMPT=$(
  awk -v branch="$BRANCH" '
    {
      gsub(/<BRANCH-NAME>/, branch)
      print
    }
  ' ./PROMPT.md
)

# Make sure required executable exists
if ! command -v "$TYPE" >/dev/null 2>&1; then
  err "'$TYPE' command not found in PATH"
fi

case "$TYPE" in
  claude)
    # Good default: latest strong model alias + high effort.
    # Non-interactive mode: -p
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
    # Good default: latest flagship model + high reasoning.
    # Non-interactive mode: codex exec
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
