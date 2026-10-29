#!/usr/bin/env bash
#
# Wrapper that runs protocol_ops (and forge / cast) either directly against
# the era-contracts checkout this script lives in, or inside a pre-built
# `ghcr.io/matter-labs/protocol-ops` Docker image.
#
# Usage:
#   ./protocol-ops.sh [--tag <docker-tag> | --tag sha256:<digest>] <command> [args...]
#
# <command>:
#   - forge | cast          → runs that binary
#   - anything else         → passed verbatim to protocol_ops
#
# Mode:
#   - no --tag              → local mode: uses this era-contracts checkout
#   - --tag <tag>           → docker mode: runs inside ghcr.io/matter-labs/protocol-ops:<tag>
#   - --tag sha256:<digest> → docker mode: runs inside ghcr.io/matter-labs/protocol-ops@sha256:<digest>
#
# Examples:
#   ./protocol-ops.sh chain init --l1-rpc-url http://localhost:8545 …
#   ./protocol-ops.sh --tag sha256:<digest> chain init --l1-rpc-url …
#   ./protocol-ops.sh forge script deploy-scripts/Foo.s.sol --rpc-url …
#   ./protocol-ops.sh --tag sha256:<digest> cast call 0xaddr 'foo()(uint256)' --rpc-url …
#
# Docker mode runs the image's own configs (l1-contracts/upgrade-envs/). Only
# outputs are mounted from this checkout: l1-contracts/script-out/ and, for every
# upgrade here with an upgrade.toml, its output/ directory, so `--env <env>`
# writes land in upgrade-envs/<v>/output/<env>/ on the host.
#
# Environment:
#   EXTRA_MOUNTS     — Docker mode: space-separated host:container mount pairs,
#                      e.g. "/tmp/out:/contracts/out", for `--out` and inputs
#                      such as a deploy bundle.
#   PROTOCOL_OPS_REQUIRE_RELEASE=1
#                    — refuse local mode and an image without the
#                      org.opencontainers.image.revision label, i.e. one not
#                      released by build-docker.yaml. The chain workflows and
#                      execute-deployer-safe-bundles set it.
#   PROTOCOL_OPS_BIN — Local mode only: path to a pre-built protocol_ops
#                      binary. If unset, the wrapper runs `cargo build
#                      --release` inside protocol-ops/ and uses the resulting
#                      target/release binary.
#   ETHERSCAN_API_KEY, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID,
#   RUNNER_OS        — Docker mode: passed into the container when set
#                      (`forge verify-contract`; the run a deploy bundle
#                      records as `generated_by`).
#
set -euo pipefail

IMAGE_REPO="ghcr.io/matter-labs/protocol-ops"

# Absolute path to the era-contracts checkout this script lives in.
ERA_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: protocol-ops.sh [--tag <docker-tag> | --tag sha256:<digest>] <command> [args...]

<command>:
  forge | cast          runs that binary
  anything else         passed verbatim to protocol_ops

Mode:
  no --tag              local mode (uses this era-contracts checkout)
  --tag <tag>           docker mode (ghcr.io/matter-labs/protocol-ops:<tag>)
  --tag sha256:<digest> docker mode (ghcr.io/matter-labs/protocol-ops@sha256:<digest>)

Examples:
  protocol-ops.sh chain init --l1-rpc-url http://localhost:8545 …
  protocol-ops.sh --tag sha256:<digest> chain init --l1-rpc-url …
  protocol-ops.sh forge script deploy-scripts/Foo.s.sol --rpc-url …
  protocol-ops.sh --tag sha256:<digest> cast call 0xaddr 'foo()(uint256)' --rpc-url …
EOF
  exit 1
}

TAG=""
if [[ "${1:-}" == "--tag" ]]; then
  shift
  [[ $# -lt 1 || -z "$1" ]] && usage
  TAG="$1"; shift
fi

[[ $# -lt 1 ]] && usage

if [[ "${PROTOCOL_OPS_REQUIRE_RELEASE:-}" == "1" && -z "$TAG" ]]; then
  echo "Error: PROTOCOL_OPS_REQUIRE_RELEASE=1 needs --tag <released image>" >&2
  exit 1
fi

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
if [[ "$TAG" == sha256:* ]]; then
  IMAGE="${IMAGE_REPO}@${TAG}"
else
  IMAGE="${IMAGE_REPO}:${TAG}"
fi

# The registry digest of the image, which `ecosystem rehearse-upgrade` records in
# the deploy bundle even when started by a (mutable) tag. Pull output goes to
# stderr: callers capture this wrapper's stdout (e.g. `cast wallet address`).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull --quiet --platform=linux/amd64 "$IMAGE" >&2
fi
IMAGE_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" \
  | grep -m1 "^${IMAGE_REPO}@" || true)"
IMAGE_REVISION="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")"

if [[ "${PROTOCOL_OPS_REQUIRE_RELEASE:-}" == "1" && -z "$IMAGE_REVISION" ]]; then
  echo "Error: ${IMAGE} has no revision label (org.opencontainers.image.revision): release an image with build-docker.yaml" >&2
  exit 1
fi
if [[ -n "$IMAGE_REVISION" && "$(git -C "$ERA_PATH" rev-parse HEAD 2>/dev/null)" != "$IMAGE_REVISION" ]]; then
  echo "Warning: ${IMAGE} is revision ${IMAGE_REVISION} and this checkout is not: upgrade-envs/*/output/ is this checkout's, and the outputs of an upgrade it lacks stay in the container" >&2
fi

HOST_SCRIPT_OUT="${ERA_PATH}/l1-contracts/script-out"
mkdir -p "${HOST_SCRIPT_OUT}"

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
  -e PROTOCOL_OPS_IMAGE="${IMAGE}"
  -e PROTOCOL_OPS_IMAGE_DIGEST="${IMAGE_DIGEST}"
  -v "${HOST_SCRIPT_OUT}:/contracts/l1-contracts/script-out"
)
for descriptor in "${ERA_PATH}"/l1-contracts/upgrade-envs/*/upgrade.toml; do
  [[ -f "$descriptor" ]] || continue
  output="${descriptor%/upgrade.toml}/output"
  mkdir -p "$output"
  docker_args+=(-v "${output}:/contracts/l1-contracts/upgrade-envs/${output#"${ERA_PATH}/l1-contracts/upgrade-envs/"}")
done

run_args=("$TOOL" "$@")

if [[ "$(uname -s)" == "Linux" ]]; then
  docker_args+=(--network=host)
  docker_args+=(-e ETH_RPC_URL="${ETH_RPC_URL:-http://localhost:8545}")
else
  # macOS / Docker Desktop: rewrite localhost → host.docker.internal in args.
  docker_args+=(--add-host=host.docker.internal:host-gateway)
  rewritten=("$TOOL")
  for arg in "$@"; do
    arg="${arg//:\/\/localhost:/://host.docker.internal:}"
    arg="${arg//:\/\/127.0.0.1:/://host.docker.internal:}"
    rewritten+=("$arg")
  done
  run_args=("${rewritten[@]}")
fi

# Passed through when set: the Etherscan key (`forge verify-contract`) and the
# GitHub Actions run a deploy bundle records as `generated_by`.
for var in ETHERSCAN_API_KEY GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID RUNNER_OS; do
  if [[ -n "${!var:-}" ]]; then
    docker_args+=(-e "$var")
  fi
done

# Extra mounts from env (space-separated "host:container" pairs).
for mount in ${EXTRA_MOUNTS:-}; do
  docker_args+=(-v "$mount")
done

if [[ -n "${container_workdir}" ]]; then
  docker_args+=(-w "${container_workdir}")
fi

docker_args+=("${IMAGE}")

exec docker "${docker_args[@]}" "${run_args[@]}"
