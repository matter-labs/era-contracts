# syntax=docker/dockerfile:1.6

ARG FOUNDRY_ARCH=linux_amd64
ARG FOUNDRY_ZKSYNC_TAG=nightly-807f47ace7cdd90eed7190dc4481952cfaa25938
ARG FOUNDRY_VANILLA_VERSION=v1.3.5
ARG NODE_MAJOR=20
ARG RUST_TARGET=x86_64-unknown-linux-gnu
ARG RUST_TOOLCHAIN=nightly-2025-09-19
ARG YARN_VERSION=1.22.19

########################################
# Base: shared tooling image
########################################
FROM debian:bookworm-slim AS base

ARG FOUNDRY_ARCH
ARG FOUNDRY_ZKSYNC_TAG
ARG FOUNDRY_VANILLA_VERSION
ARG NODE_MAJOR
ARG RUST_TARGET
ARG RUST_TOOLCHAIN
ARG YARN_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/cargo/bin:/usr/local/bin:$PATH \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo

# Build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git bash coreutils openssl jq xz-utils gnupg \
      build-essential pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Node + Yarn
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 && npm i -g yarn@${YARN_VERSION} \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# Foundry zksync (forge + cast)
RUN curl -L -o /tmp/foundry.tgz https://github.com/matter-labs/foundry-zksync/releases/download/${FOUNDRY_ZKSYNC_TAG}/foundry_zksync_nightly_${FOUNDRY_ARCH}.tar.gz \
 && tar zxf /tmp/foundry.tgz -C /usr/local/bin/ \
 && chmod +x /usr/local/bin/forge /usr/local/bin/cast \
 && rm /tmp/foundry.tgz

# Foundry vanilla (anvil)
RUN curl -L -o /tmp/foundry-vanilla.tgz https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VANILLA_VERSION}/foundry_${FOUNDRY_VANILLA_VERSION}_${FOUNDRY_ARCH}.tar.gz \
 && tar zxf /tmp/foundry-vanilla.tgz -C /tmp/ anvil \
 && mv /tmp/anvil /usr/local/bin/anvil \
 && chmod +x /usr/local/bin/anvil \
 && rm /tmp/foundry-vanilla.tgz

# Rust + cargo-chef
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain ${RUST_TOOLCHAIN} --no-modify-path
RUN rustup target add ${RUST_TARGET}
RUN cargo install cargo-chef --locked

########################################
# Stage: prepare recipes (fast, only reads manifests)
########################################
FROM base AS planner

WORKDIR /src
COPY . /src

# Each crate has its own workspace — prepare a recipe for each.
RUN mkdir -p /recipes && \
    cd protocol-ops && cargo chef prepare --recipe-path /recipes/protocol-ops.json
RUN cd tools/zksync-os-genesis-gen && cargo chef prepare --recipe-path /recipes/genesis-gen.json
RUN cd tools/wallets-gen && cargo chef prepare --recipe-path /recipes/wallets-gen.json

########################################
# Stage: build Rust binaries (cached dep layers via cargo-chef)
########################################
FROM base AS rust-builder

ARG RUST_TARGET

# -- Cook dependencies (cached until Cargo.toml/lock change) --
WORKDIR /build/protocol-ops
COPY --from=planner /recipes/protocol-ops.json recipe.json
RUN cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

WORKDIR /build/genesis-gen
COPY --from=planner /recipes/genesis-gen.json recipe.json
COPY tools/zksync-os-genesis-gen/rust-toolchain.toml ./
RUN cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

WORKDIR /build/wallets-gen
COPY --from=planner /recipes/wallets-gen.json recipe.json
RUN cargo chef cook --release --target ${RUST_TARGET} --recipe-path recipe.json

# -- Build actual binaries (only source changes invalidate this) --
WORKDIR /build/protocol-ops
COPY protocol-ops/ ./
RUN cargo build --bin protocol_ops --release --target ${RUST_TARGET}

WORKDIR /build/genesis-gen
COPY tools/zksync-os-genesis-gen/ ./
RUN cargo build --release --target ${RUST_TARGET}

WORKDIR /build/wallets-gen
COPY tools/wallets-gen/ ./
RUN cargo build --release --target ${RUST_TARGET}

########################################
# Stage: build Solidity contracts (parallel with rust-builder)
########################################
FROM base AS contracts-builder

WORKDIR /contracts
COPY . /contracts

ENV YARN_CACHE_FOLDER=/tmp/yarn-cache
RUN yarn install --frozen-lockfile

# Clean + compile
RUN forge clean --root da-contracts && \
    yarn --cwd l1-contracts clean && forge clean --root l1-contracts && \
    yarn --cwd l2-contracts clean && forge clean --root l2-contracts && \
    yarn --cwd system-contracts clean && forge clean --root system-contracts

RUN yarn --cwd da-contracts build:foundry && \
    yarn --cwd l1-contracts build:foundry && \
    yarn --cwd l2-contracts build:foundry && \
    yarn --cwd system-contracts build:foundry

RUN yarn calculate-hashes:check

# Keep full node_modules — forge ffi scripts need devDependencies (ts-node, typescript, etc.)

########################################
# Runtime
########################################
FROM debian:bookworm-slim

ARG NODE_MAJOR
ARG YARN_VERSION
ARG RUST_TARGET

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH \
    FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    XDG_CONFIG_HOME=/etc/xdg

# Runtime deps + Node.js (needed for forge ffi scripts like blake2s256.ts)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates bash openssl jq curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    npm i -g yarn@${YARN_VERSION} && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/*

# Foundry binaries
COPY --from=contracts-builder /usr/local/bin/forge /usr/local/bin/forge
COPY --from=contracts-builder /usr/local/bin/cast  /usr/local/bin/cast
COPY --from=contracts-builder /usr/local/bin/anvil /usr/local/bin/anvil

# Rust binaries
COPY --from=rust-builder /build/protocol-ops/target/${RUST_TARGET}/release/protocol_ops /usr/local/bin/
COPY --from=rust-builder /build/genesis-gen/target/${RUST_TARGET}/release/zksync-os-genesis-gen /usr/local/bin/
COPY --from=rust-builder /build/wallets-gen/target/${RUST_TARGET}/release/wallets-gen /usr/local/bin/

# Compiled contracts + configs
WORKDIR /contracts
COPY --from=contracts-builder /contracts/configs /contracts/configs
COPY --from=contracts-builder /contracts/l1-contracts /contracts/l1-contracts
COPY --from=contracts-builder /contracts/l2-contracts /contracts/l2-contracts
COPY --from=contracts-builder /contracts/system-contracts /contracts/system-contracts
COPY --from=contracts-builder /contracts/da-contracts /contracts/da-contracts
COPY --from=contracts-builder /contracts/lib /contracts/lib
COPY --from=contracts-builder /contracts/node_modules /contracts/node_modules
COPY --from=contracts-builder /contracts/package.json /contracts/package.json
COPY --from=contracts-builder /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json
COPY --from=contracts-builder /contracts/SystemConfig.json /contracts/SystemConfig.json

# Disable foundry-zksync telemetry
RUN mkdir -p /etc/xdg/zksync-tooling && \
    echo '{"enabled":false,"instance_id":"00000000-0000-0000-0000-000000000000","created_at":"2024-01-01T00:00:00Z","config_path":null}' \
    > /etc/xdg/zksync-tooling/telemetry.json

# Sanity
RUN forge --version && cast --version && anvil --version && protocol_ops --help && \
    zksync-os-genesis-gen --help && wallets-gen --help && node --version && yarn --version
