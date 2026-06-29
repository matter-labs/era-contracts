#!/usr/bin/env bash
#
# Wrapper that runs protocol_ops (and forge / cast) either directly against
# the era-contracts checkout this script lives in, or inside a pre-built
# `ghcr.io/matter-labs/protocol-ops` Docker image.
#
# Usage:
#   ./protocol-ops.sh [--tag <docker-tag>] <command> [args...]
#
# <command>:
#   - forge | cast          → runs that binary
#   - anything else         → passed verbatim to protocol_ops
#
# Mode:
#   - no --tag              → local mode: uses this era-contracts checkout
#   - --tag <tag>           → docker mode: runs inside ghcr.io/matter-labs/protocol-ops:<tag>
#
# Examples:
#   ./protocol-ops.sh chain init --l1-rpc-url http://localhost:8545 …
#   ./protocol-ops.sh --tag latest chain init --l1-rpc-url …
#   ./protocol-ops.sh forge script deploy-scripts/Foo.s.sol --rpc-url …
#   ./protocol-ops.sh --tag latest cast call 0xaddr 'foo()(uint256)' --rpc-url …
#
# Environment:
#   WORK_DIR         — Docker mode: host directory mounted into the container
#                      for output files (default: ./protocol-ops-workdir).
#                      Ignored in local mode.
#   EXTRA_MOUNTS     — Docker mode: space-separated host:container mount pairs,
#                      e.g. "/tmp/cfg:/contracts/cfg".
#   PROTOCOL_OPS_BIN — Local mode only: path to a pre-built protocol_ops
#                      binary. If unset, the wrapper runs `cargo build
#                      --release` inside protocol-ops/ and uses the resulting
#                      target/release binary.
#
set -euo pipefail

IMAGE_REPO="ghcr.io/matter-labs/protocol-ops"

# Absolute path to the era-contracts checkout this script lives in.
ERA_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: protocol-ops.sh [--tag <docker-tag>] <command> [args...]

<command>:
  forge | cast          runs that binary
  anything else         passed verbatim to protocol_ops

Mode:
  no --tag              local mode (uses this era-contracts checkout)
  --tag <tag>           docker mode (ghcr.io/matter-labs/protocol-ops:<tag>)

Examples:
  protocol-ops.sh chain init --l1-rpc-url http://localhost:8545 …
  protocol-ops.sh --tag latest chain init --l1-rpc-url …
  protocol-ops.sh forge script deploy-scripts/Foo.s.sol --rpc-url …
  protocol-ops.sh --tag latest cast call 0xaddr 'foo()(uint256)' --rpc-url …
EOF
  exit 1
}

TAG=""
if [[ "${1:-}" == "--tag" ]]; then
  shift
  [[ $# -lt 1 ]] && usage
  TAG="$1"; shift
fi

[[ $# -lt 1 ]] && usage

# Determine which tool to run. Only forge / cast are passed through verbatim;
# anything else is assumed to be a protocol_ops subcommand.
case "$1" in
  forge|cast)
    TOOL="$1"; shift
    ;;
  *)
    TOOL="protocol_ops"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────
# Local mode
# ──────────────────────────────────────────────────────────────────────
if [[ -z "$TAG" ]]; then
  if [[ ! -d "$ERA_PATH/protocol-ops" || ! -d "$ERA_PATH/l1-contracts" ]]; then
    echo "error: '$ERA_PATH' does not look like an era-contracts checkout" >&2
    echo "       (missing protocol-ops/ or l1-contracts/ subdirectory)" >&2
    exit 1
  fi

  case "$TOOL" in
    protocol_ops)
      BIN="${PROTOCOL_OPS_BIN:-}"
      if [[ -z "$BIN" ]]; then
        BIN="$ERA_PATH/protocol-ops/target/release/protocol_ops"
        # Always rebuild — cargo is a no-op when nothing changed.
        (cd "$ERA_PATH/protocol-ops" && cargo build --release --quiet)
      fi
      exec env PROTOCOL_CONTRACTS_ROOT="$ERA_PATH" "$BIN" "$@"
      ;;
    forge)
      # forge must run from the l1-contracts directory so it can find
      # foundry.toml and the Solidity sources.
      cd "$ERA_PATH/l1-contracts"
      exec env PROTOCOL_CONTRACTS_ROOT="$ERA_PATH" forge "$@"
      ;;
    cast)
      exec cast "$@"
      ;;
  esac
fi

# ──────────────────────────────────────────────────────────────────────
# Docker mode
# ──────────────────────────────────────────────────────────────────────
IMAGE="${IMAGE_REPO}:${TAG}"

WORK_DIR="${WORK_DIR:-$(pwd)/protocol-ops-workdir}"
mkdir -p "${WORK_DIR}/script-out"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"   # absolute path

CONTAINER_WORK="/contracts/work/session"

# Container-side working directory. forge needs /contracts/l1-contracts so it
# can find foundry.toml; protocol_ops and cast don't care.
container_workdir=""
if [[ "$TOOL" == "forge" ]]; then
  container_workdir="/contracts/l1-contracts"
fi

# ── Platform-specific networking ──────────────────────────────────────
# Linux: --network=host lets the container reach localhost directly.
# macOS (Docker Desktop): host network mode doesn't work; use
#   host.docker.internal and rewrite localhost / 127.0.0.1 URLs in args.
docker_args=(
  run --rm
  --platform=linux/amd64
  -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1
  -v "${WORK_DIR}:${CONTAINER_WORK}"
  -v "${WORK_DIR}/script-out:/contracts/l1-contracts/script-out"
)

run_args=("$TOOL" "$@")

if [[ "$(uname -s)" == "Linux" ]]; then
  docker_args+=(--network=host)
  docker_args+=(-e ETH_RPC_URL="${ETH_RPC_URL:-http://localhost:8545}")
else
  # macOS / Docker Desktop: rewrite localhost → host.docker.internal in args.
  docker_args+=(--add-host=host.docker.internal:host-gateway)
  rewritten=("$TOOL")
  for arg in "$@"; do
    arg="${arg//:\/\/localhost:/:\/\/host.docker.internal:}"
    arg="${arg//:\/\/127.0.0.1:/:\/\/host.docker.internal:}"
    rewritten+=("$arg")
  done
  run_args=("${rewritten[@]}")
fi

# Extra mounts from env (space-separated "host:container" pairs).
for mount in ${EXTRA_MOUNTS:-}; do
  docker_args+=(-v "$mount")
done

if [[ -n "${container_workdir}" ]]; then
  docker_args+=(-w "${container_workdir}")
fi

docker_args+=("${IMAGE}")

exec docker "${docker_args[@]}" "${run_args[@]}"
