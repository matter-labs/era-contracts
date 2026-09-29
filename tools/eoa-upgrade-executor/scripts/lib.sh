# Shared helpers for the eoa-upgrade-executor scripts. Source it, do not run it.
# Written for bash 3.2 (the macOS default) so the scripts also run on a laptop.
# shellcheck shell=bash

set -euo pipefail

EXECUTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# EXECUTOR_CONFIG exists only so the tests can point at a local-anvil network.
CONFIG_FILE="${EXECUTOR_CONFIG:-${EXECUTOR_ROOT}/config.json}"
CAST="${CAST:-cast}"
ANVIL="${ANVIL:-anvil}"
EXPECTED_FOUNDRY_VERSION="1.5.1-v1.5.1"
FIRST_ANVIL_PORT=8645

log() { printf '%s\n' "$*" >&2; }

# Prints the message and exits. In GitHub Actions it is also an ::error::
# annotation, escaped so that it cannot inject workflow commands. The tests set
# EXECUTOR_TEST to keep their expected failures out of the annotations.
die() {
  local msg="$*"
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${EXECUTOR_TEST:-}" ]; then
    local esc="${msg//'%'/%25}"
    esc="${esc//$'\r'/%0D}"
    esc="${esc//$'\n'/%0A}"
    printf '::error::%s\n' "$esc"
  fi
  printf 'ERROR: %s\n' "$msg" >&2
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

check_foundry() {
  require_cmd "$CAST" jq
  local v
  v="$("$CAST" --version | head -n 1)"
  case "$v" in
    *"$EXPECTED_FOUNDRY_VERSION"*) ;;
    *) log "WARNING: expected upstream foundry $EXPECTED_FOUNDRY_VERSION, got: $v (set CAST=/path/to/cast to override)" ;;
  esac
}

cfg() { jq -er "$@" "$CONFIG_FILE"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# A commit of the repository the workflow runs in: full 40-hex, lower case.
validate_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] ||
    die "source commit must be a full 40-hex lowercase SHA (branch and tag names are rejected), got: '$1'"
}

# A repo-relative .json path. Every segment starts with a letter, digit or '_',
# so there is no '.', '..', leading '/', leading '-' or glob character.
validate_source_path() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*\.json$ ]] ||
    die "path must be a repo-relative path to a .json file (no '.' or '..' segments), got: '$1'"
}

network_of_env() {
  cfg --arg e "$1" '.environments[$e].network // empty' 2>/dev/null ||
    die "unknown environment '$1' (known: $(jq -r '.environments | keys | join(", ")' "$CONFIG_FILE"))"
}
chain_id_of_network() { cfg --arg n "$1" '.networks[$n].chainId'; }
rpc_of_network() { cfg --arg n "$1" '.networks[$n].rpcUrl'; }

# The RPC must serve the chain the plan was built for.
require_chain_id() {
  local rpc="$1" expected="$2" actual
  actual="$("$CAST" chain-id --rpc-url "$rpc")" || die "cannot reach the RPC to read its chain id"
  [ "$actual" = "$expected" ] || die "chain id mismatch: RPC serves $actual, expected $expected"
}

# First port at or above $1 on which nothing listens.
find_free_port() {
  local p="$1" last=$(($1 + 200))
  while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do
    p=$((p + 1))
    [ "$p" -le "$last" ] || die "no free port found near $1"
  done
  printf '%s\n' "$p"
}

# Waits until the RPC answers, or fails if the process that serves it died.
wait_for_rpc() {
  local rpc="$1" pid="$2" tries="${3:-120}" i=0
  until "$CAST" chain-id --rpc-url "$rpc" >/dev/null 2>&1; do
    kill -0 "$pid" 2>/dev/null || die "anvil (pid $pid) exited before its RPC came up"
    i=$((i + 1))
    [ "$i" -le "$tries" ] || die "RPC $rpc did not come up"
    sleep 1
  done
}

# Markdown-safe single-line rendering of untrusted text (descriptions, labels).
md_escape() { printf '%s' "$1" | tr -d '\r\n' | sed -e 's/|/\\|/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/`/\\`/g'; }
