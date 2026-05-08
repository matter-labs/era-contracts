# syntax=docker/dockerfile:1.6

ARG FOUNDRY_ARCH=linux_amd64
ARG FOUNDRY_ZKSYNC_TAG=nightly-807f47ace7cdd90eed7190dc4481952cfaa25938
ARG FOUNDRY_VANILLA_VERSION=v1.5.1
ARG NODE_MAJOR=20
ARG RUST_TARGET=x86_64-unknown-linux-gnu
ARG RUST_TOOLCHAIN=nightly-2025-09-19
ARG YARN_VERSION=1.22.19
# Pre-baked toolchain base for the build stages (see Dockerfile.base +
# build-docker-base.yaml). Must be a global ARG so it's visible in the
# `FROM ${BUILD_BASE_IMAGE}` lines below.
ARG BUILD_BASE_IMAGE=ghcr.io/matter-labs/protocol-ops-base:latest

########################################
# 1) Planner — prepare cargo-chef recipes
########################################
FROM lukemathwalker/cargo-chef:latest-rust-1 AS planner

COPY protocol-ops /src/protocol-ops
COPY tools/zksync-os-genesis-gen /src/tools/zksync-os-genesis-gen
COPY tools/wallets-gen /src/tools/wallets-gen
COPY tools/upgrade-readiness-checker /src/tools/upgrade-readiness-checker

RUN mkdir -p /recipes && \
    cd /src/protocol-ops && cargo chef prepare --recipe-path /recipes/protocol-ops.json && \
    cd /src/tools/zksync-os-genesis-gen && cargo chef prepare --recipe-path /recipes/genesis-gen.json && \
    cd /src/tools/wallets-gen && cargo chef prepare --recipe-path /recipes/wallets-gen.json && \
    cd /src/tools/upgrade-readiness-checker && cargo chef prepare --recipe-path /recipes/upgrade-readiness-checker.json

########################################
# 2a) Rust build (parallel with 2b)
########################################
# Compiles the 4 binaries in isolation. Buildkit auto-parallelizes this stage
# with the forge-builder stage below (no cross-deps). The only contract input
# Rust needs is `l1-contracts/zkstack-out/` (committed JSON ABIs read by
# `abigen!` macros at compile time) — we COPY that subset rather than the
# whole tree so a Solidity-only change doesn't invalidate the cargo layers.
FROM ${BUILD_BASE_IMAGE} AS cargo-builder

ARG RUST_TARGET

WORKDIR /contracts

# === Cook Rust dependencies (cached until Cargo.toml/lock change) ===
# BuildKit cache mounts:
#   - /usr/local/cargo/{registry,git} are shared across all four cooks AND the
#     subsequent cargo build steps (one crates.io fetch, reused 8x).
#   - Each `target/` mount has its own `id=` so the four crates don't fight over
#     the same incremental directory; the same id is reused by the later
#     `cargo build --release` so it doesn't redo dep compilation.
# `sharing=locked` is conservative — it serializes concurrent access, fine here
# because the four cooks are sequential anyway.
WORKDIR /contracts/protocol-ops
COPY --from=planner /recipes/protocol-ops.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/protocol-ops/target,id=protocol-ops-target,sharing=locked \
    cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

WORKDIR /contracts/tools/zksync-os-genesis-gen
COPY --from=planner /recipes/genesis-gen.json recipe.json
COPY tools/zksync-os-genesis-gen/rust-toolchain.toml ./
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/zksync-os-genesis-gen/target,id=genesis-gen-target,sharing=locked \
    cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

WORKDIR /contracts/tools/wallets-gen
COPY --from=planner /recipes/wallets-gen.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/wallets-gen/target,id=wallets-gen-target,sharing=locked \
    cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

WORKDIR /contracts/tools/upgrade-readiness-checker
COPY --from=planner /recipes/upgrade-readiness-checker.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/upgrade-readiness-checker/target,id=upgrade-readiness-checker-target,sharing=locked \
    cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

# === Copy Rust source + the only contract input cargo needs (zkstack-out) ===
WORKDIR /contracts
COPY protocol-ops /contracts/protocol-ops
COPY tools /contracts/tools
COPY l1-contracts/zkstack-out /contracts/l1-contracts/zkstack-out

# === Build Rust binaries (deps already cached by cook) ===
WORKDIR /contracts/protocol-ops
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/protocol-ops/target,id=protocol-ops-target,sharing=locked \
    cargo build --bin protocol_ops --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/protocol_ops ./

WORKDIR /contracts/tools/zksync-os-genesis-gen
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/zksync-os-genesis-gen/target,id=genesis-gen-target,sharing=locked \
    cargo build --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/zksync-os-genesis-gen ./

WORKDIR /contracts/tools/wallets-gen
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/wallets-gen/target,id=wallets-gen-target,sharing=locked \
    cargo build --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/wallets-gen ./

WORKDIR /contracts/tools/upgrade-readiness-checker
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/tools/upgrade-readiness-checker/target,id=upgrade-readiness-checker-target,sharing=locked \
    cargo build --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/upgrade-readiness-checker ./

########################################
# 2b) Forge build (parallel with 2a)
########################################
# yarn install + forge build for each contracts subproject + zk-governance.
# Independent of cargo-builder, so buildkit runs them in parallel — wall-time
# of the build stage drops to max(rust, forge) instead of rust + forge.
FROM ${BUILD_BASE_IMAGE} AS forge-builder

WORKDIR /contracts

# === Copy all source code ===
COPY . /contracts

# === Copy zk-governance source ===
# protocol-ops's PUH/Guardians redeploy step (`ecosystem upgrade-prepare-all`
# on PUH-governed envs like stage / mainnet) shells out to a forge script
# inside zk-governance. The runtime path it expects is `<era>/../../zk-governance`,
# which inside the container resolves to `/zk-governance` (foundry root with
# `foundry.toml` at the top level — no `l1-contracts/` wrapper). The CI
# workflow checks out zksync-association/zk-governance at
# $GITHUB_WORKSPACE/zk-governance/ so it lands inside the docker build context.
COPY zk-governance /zk-governance

# === Install JS dependencies ===
RUN yarn install --frozen-lockfile

# === Clean + compile contracts ===
RUN forge clean --root da-contracts
RUN yarn --cwd l1-contracts clean
RUN forge clean --root l1-contracts
RUN yarn --cwd l2-contracts clean
RUN forge clean --root l2-contracts
RUN yarn --cwd system-contracts clean
RUN forge clean --root system-contracts

RUN yarn --cwd da-contracts build:foundry
RUN yarn --cwd l1-contracts build:foundry
RUN yarn --cwd l2-contracts build:foundry
RUN yarn --cwd system-contracts build:foundry

# Pre-compile zk-governance contracts. This both seeds /root/.svm/ with solc
# 0.8.24 (zk-governance pins it; the runtime image runs with FOUNDRY_OFFLINE=true
# so missing solc downloads would fail) and produces out/ artifacts that
# DeployPUHAndGuardians.s.sol reads at runtime. Some refs wrap the foundry
# project in `l1-contracts/`; pick whichever holds `foundry.toml`.
RUN if [ -f /zk-governance/foundry.toml ]; then \
      cd /zk-governance && forge build; \
    elif [ -f /zk-governance/l1-contracts/foundry.toml ]; then \
      cd /zk-governance/l1-contracts && forge build; \
    else \
      echo "zk-governance foundry root not found" >&2 && exit 1; \
    fi

# Keep full node_modules — forge ffi scripts depend on packages here (e.g. blakejs).

########################################
# 3) Runtime
########################################
FROM debian:bookworm-slim

ARG NODE_MAJOR
ARG YARN_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/contracts/protocol-ops:/contracts/tools/zksync-os-genesis-gen:/contracts/tools/wallets-gen:/contracts/tools/upgrade-readiness-checker:/usr/local/bin:$PATH \
    FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    FOUNDRY_OFFLINE=true \
    XDG_CONFIG_HOME=/etc/xdg

# Runtime deps + Node.js (needed for forge ffi scripts like blake2s256.js)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates bash openssl jq curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    npm i -g yarn@${YARN_VERSION} && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/*

# === Copy foundry binaries and solc cache from forge-builder ===
COPY --from=forge-builder /usr/local/bin/forge /usr/local/bin/forge
COPY --from=forge-builder /usr/local/bin/cast  /usr/local/bin/cast
COPY --from=forge-builder /usr/local/bin/anvil /usr/local/bin/anvil
COPY --from=forge-builder /root/.svm /root/.svm
# === Copy protocol_ops and tools binaries from cargo-builder ===
COPY --from=cargo-builder /contracts/protocol-ops/protocol_ops /contracts/protocol-ops/protocol_ops
COPY --from=cargo-builder /contracts/tools/zksync-os-genesis-gen/zksync-os-genesis-gen /contracts/tools/zksync-os-genesis-gen/zksync-os-genesis-gen
COPY --from=cargo-builder /contracts/tools/wallets-gen/wallets-gen /contracts/tools/wallets-gen/wallets-gen
COPY --from=cargo-builder /contracts/tools/upgrade-readiness-checker/upgrade-readiness-checker /contracts/tools/upgrade-readiness-checker/upgrade-readiness-checker

# === Set new WORKDIR and copy contract artifacts from forge-builder ===
WORKDIR /contracts
COPY --from=forge-builder /contracts/configs /contracts/configs
COPY --from=forge-builder /contracts/l1-contracts /contracts/l1-contracts
COPY --from=forge-builder /contracts/l2-contracts /contracts/l2-contracts
COPY --from=forge-builder /contracts/system-contracts /contracts/system-contracts
COPY --from=forge-builder /contracts/da-contracts /contracts/da-contracts
COPY --from=forge-builder /contracts/lib /contracts/lib
COPY --from=forge-builder /contracts/node_modules /contracts/node_modules
COPY --from=forge-builder /contracts/package.json /contracts/package.json
COPY --from=forge-builder /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json
COPY --from=forge-builder /contracts/SystemConfig.json /contracts/SystemConfig.json

# zk-governance lives at `/zk-governance` (sibling-style path) so protocol-ops
# resolves it correctly via `<era>/../../zk-governance`.
COPY --from=forge-builder /zk-governance /zk-governance

# Disable foundry-zksync telemetry
RUN mkdir -p /etc/xdg/zksync-tooling && \
    echo '{"enabled":false,"instance_id":"00000000-0000-0000-0000-000000000000","created_at":"2024-01-01T00:00:00Z","config_path":null}' \
    > /etc/xdg/zksync-tooling/telemetry.json

# Sanity
RUN forge --version && cast --version && anvil --version && protocol_ops --help && \
    zksync-os-genesis-gen --help && wallets-gen --help && upgrade-readiness-checker --help && \
    node --version && yarn --version
