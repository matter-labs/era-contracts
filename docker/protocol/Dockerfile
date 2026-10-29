# syntax=docker/dockerfile:1.6

ARG NODE_MAJOR=20
ARG RUST_TARGET=x86_64-unknown-linux-gnu
ARG RUST_TOOLCHAIN=nightly-2025-09-19
ARG YARN_VERSION=1.22.19
# Pre-baked toolchain base for the build stages (see Dockerfile.base +
# build-docker-base.yaml). Must be a global ARG so it's visible in the
# `FROM ${BUILD_BASE_IMAGE}` lines below.
ARG BUILD_BASE_IMAGE=ghcr.io/matter-labs/protocol-ops-base:latest
# The zksync-association/zk-governance commit the image holds at /zk-governance.
ARG ZK_GOVERNANCE_COMMIT=9b06a16159cd58add109f25598e79731450d1772

########################################
# 1) Planner — prepare cargo-chef recipes
########################################
FROM lukemathwalker/cargo-chef:latest-rust-1 AS planner

COPY protocol-ops /src/protocol-ops
COPY tools/wallets-gen /src/tools/wallets-gen
COPY tools/upgrade-readiness-checker /src/tools/upgrade-readiness-checker

RUN mkdir -p /recipes && \
    cd /src/protocol-ops && cargo chef prepare --recipe-path /recipes/protocol-ops.json && \
    cd /src/tools/wallets-gen && cargo chef prepare --recipe-path /recipes/wallets-gen.json && \
    cd /src/tools/upgrade-readiness-checker && cargo chef prepare --recipe-path /recipes/upgrade-readiness-checker.json

########################################
# 2a) Rust build (parallel with 2b)
########################################
# Compiles the 3 binaries in isolation. Not tools/zksync-os-genesis-gen: it
# depends on the private zksync-os-private repo, and nothing in the image runs
# it. Buildkit auto-parallelizes this stage with the forge-builder stage below (no
# cross-deps). The only contract input Rust needs is `l1-contracts/zkstack-out/`
# (committed JSON ABIs read by `abigen!` macros at compile time) — we COPY that
# subset rather than the whole tree so a Solidity-only change doesn't
# invalidate the cargo layers.
FROM ${BUILD_BASE_IMAGE} AS cargo-builder

ARG RUST_TARGET

WORKDIR /contracts

# === Cook Rust dependencies (cached until Cargo.toml/lock change) ===
# BuildKit cache mounts:
#   - /usr/local/cargo/{registry,git} are shared across all three cooks AND the
#     subsequent cargo build steps (one crates.io fetch, reused 6x).
#   - Each `target/` mount has its own `id=` so the three crates don't fight over
#     the same incremental directory; the same id is reused by the later
#     `cargo build --release` so it doesn't redo dep compilation.
# `sharing=locked` is conservative — it serializes concurrent access, fine here
# because the three cooks are sequential anyway.
WORKDIR /contracts/protocol-ops
COPY --from=planner /recipes/protocol-ops.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/contracts/protocol-ops/target,id=protocol-ops-target,sharing=locked \
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

# === Install JS dependencies before copying source ===
# yarn install only depends on the per-workspace package.json files +
# yarn.lock. Copying just those first lets the node_modules layer stay
# cached when ONLY Solidity / TS source changes — saves ~1-2 min wall time
# per warm-cache rebuild. `.dockerignore` excludes the host's node_modules,
# so the subsequent `COPY . /contracts` only overlays source on top.
COPY package.json yarn.lock /contracts/
COPY l1-contracts/package.json /contracts/l1-contracts/
RUN yarn install --frozen-lockfile

# === zk-governance ===
# protocol-ops's PUH/Guardians redeploy step (`ecosystem upgrade-prepare-all`
# on PUH-governed envs like stage / mainnet) shells out to a forge script
# inside zk-governance, at `<era>/../../zk-governance` = `/zk-governance`.
# Building it also seeds /root/.svm/ with the solc it pins (the runtime image
# runs with FOUNDRY_OFFLINE=true) and produces the out/ artifacts the script
# reads. Some refs wrap the foundry project in `l1-contracts/`.
ARG ZK_GOVERNANCE_COMMIT
RUN git init -q /zk-governance && cd /zk-governance && \
    git fetch -q --depth 1 https://github.com/zksync-association/zk-governance "$ZK_GOVERNANCE_COMMIT" && \
    git checkout -q FETCH_HEAD && \
    git submodule update -q --init --recursive --depth 1 && \
    if [ -f foundry.toml ]; then forge build; \
    elif [ -f l1-contracts/foundry.toml ]; then cd l1-contracts && forge build; \
    else echo "zk-governance foundry root not found" >&2 && exit 1; \
    fi

# === Copy all source code ===
# `.dockerignore` excludes node_modules / out / zkout / cache / target /
# broadcast, so this layer only invalidates when a real source file
# changes. No need for the previous `forge clean` / `yarn clean` dance —
# the container always starts from a fresh build dir.
COPY . /contracts

# === Compile contracts ===
# Bytecode drift detection (`AllContractsHashes.json` ↔ built artifacts) is
# NOT done here — it lives in the dedicated `Update Hashes in PR` workflow
# (`.github/workflows/update-hashes-on-demand.yaml`) which devs trigger
# manually to regenerate + commit the hash file back to the PR. Failing the
# docker build on stale hashes would force every contract-touching branch
# through a "trigger regen → wait → re-trigger docker" loop.
RUN yarn --cwd l1-contracts build:foundry

# Keep full node_modules — forge ffi scripts depend on packages here (e.g. blakejs).

########################################
# 3) Runtime
########################################
FROM debian:bookworm-slim

ARG NODE_MAJOR
ARG YARN_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/contracts/protocol-ops:/contracts/tools/wallets-gen:/contracts/tools/upgrade-readiness-checker:/usr/local/bin:$PATH \
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
COPY --from=cargo-builder /contracts/tools/wallets-gen/wallets-gen /contracts/tools/wallets-gen/wallets-gen
COPY --from=cargo-builder /contracts/tools/upgrade-readiness-checker/upgrade-readiness-checker /contracts/tools/upgrade-readiness-checker/upgrade-readiness-checker

# === Set new WORKDIR and copy contract artifacts from forge-builder ===
WORKDIR /contracts
COPY --from=forge-builder /contracts/configs /contracts/configs
COPY --from=forge-builder /contracts/l1-contracts /contracts/l1-contracts
COPY --from=forge-builder /contracts/lib /contracts/lib
COPY --from=forge-builder /contracts/node_modules /contracts/node_modules
COPY --from=forge-builder /contracts/package.json /contracts/package.json
COPY --from=forge-builder /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json

# zk-governance lives at `/zk-governance` (sibling-style path) so protocol-ops
# resolves it correctly via `<era>/../../zk-governance`.
COPY --from=forge-builder /zk-governance /zk-governance

# Repository files read at runtime: the ZiSK backend pin (the verifier), and the
# hash script build-docker.yaml checks a release's build with.
COPY --from=forge-builder /contracts/tools/verifier-gen/data/ZiSK_plonk_backend.toml /contracts/tools/verifier-gen/data/ZiSK_plonk_backend.toml
COPY --from=forge-builder /contracts/scripts/calculate-hashes.ts /contracts/scripts/calculate-hashes.ts

# Sanity
RUN forge --version && cast --version && anvil --version && protocol_ops --help && \
    wallets-gen --help && upgrade-readiness-checker --help && \
    node --version && yarn --version

# Provenance recorded in deploy bundles (the image has no git). Last, so a new
# commit only invalidates this layer.
ARG ZK_GOVERNANCE_COMMIT
ARG CONTRACTS_COMMIT=""
ENV PROTOCOL_OPS_BIN=/contracts/protocol-ops/protocol_ops \
    PROTOCOL_OPS_CONTRACTS_COMMIT=${CONTRACTS_COMMIT} \
    PROTOCOL_OPS_ZK_GOVERNANCE_COMMIT=${ZK_GOVERNANCE_COMMIT}
