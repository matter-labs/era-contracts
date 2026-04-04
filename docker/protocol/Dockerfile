# syntax=docker/dockerfile:1.6

ARG FOUNDRY_ARCH=linux_amd64
ARG FOUNDRY_ZKSYNC_TAG=nightly-807f47ace7cdd90eed7190dc4481952cfaa25938
ARG FOUNDRY_VANILLA_VERSION=v1.3.5
ARG NODE_MAJOR=20
ARG RUST_TARGET=x86_64-unknown-linux-gnu
ARG RUST_TOOLCHAIN=nightly-2025-09-19
ARG YARN_VERSION=1.22.19

########################################
# 1) Build
########################################
FROM debian:bookworm-slim AS build

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
    CARGO_HOME=/usr/local/cargo \
    YARN_CACHE_FOLDER=/tmp/yarn-cache

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

# === Install Rust ===
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain ${RUST_TOOLCHAIN} --no-modify-path

# === Install target ===
RUN rustup target add ${RUST_TARGET}

# === Copy all source code and install dependencies ===
WORKDIR /contracts
COPY . /contracts

# === Build protocol_ops ===
WORKDIR /contracts/protocol-ops
RUN cargo build --bin protocol_ops --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/protocol_ops /usr/local/bin/ && \
    rm -rf target

# === Build zksync-os-genesis-gen ===
WORKDIR /contracts/tools/zksync-os-genesis-gen
RUN cargo build --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/zksync-os-genesis-gen /usr/local/bin/ && \
    rm -rf target

# === Build wallets-gen ===
WORKDIR /contracts/tools/wallets-gen
RUN cargo build --release --target ${RUST_TARGET} && \
    cp target/${RUST_TARGET}/release/wallets-gen /usr/local/bin/ && \
    rm -rf target

# === Install dependencies ===
WORKDIR /contracts
RUN yarn install --frozen-lockfile

# === Clean ===
RUN forge clean --root da-contracts
RUN yarn --cwd l1-contracts clean
RUN forge clean --root l1-contracts
RUN yarn --cwd l2-contracts clean
RUN forge clean --root l2-contracts
RUN yarn --cwd system-contracts clean
RUN forge clean --root system-contracts

# === Compile contracts ===
RUN yarn --cwd da-contracts build:foundry
RUN yarn --cwd l1-contracts build:foundry
RUN yarn --cwd l2-contracts build:foundry
RUN yarn --cwd system-contracts build:foundry

# === Calculate hashes ===
RUN yarn calculate-hashes:check

# === Prune dev dependencies (keep production deps for ffi scripts) ===
RUN yarn install --frozen-lockfile --production

########################################
# 2) Runtime
########################################
FROM debian:bookworm-slim

ARG NODE_MAJOR
ARG YARN_VERSION

# === Pass build arg for copying the correct binary ===
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH \
    FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
    XDG_CONFIG_HOME=/etc/xdg

# Runtime deps + Node.js (needed for forge ffi scripts like blake2s256.ts)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates bash openssl jq curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    npm i -g yarn@${YARN_VERSION} ts-node typescript && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/*

# === Copy foundry binaries from build stage ===
COPY --from=build /usr/local/bin/forge /usr/local/bin/forge
COPY --from=build /usr/local/bin/cast  /usr/local/bin/cast
COPY --from=build /usr/local/bin/anvil /usr/local/bin/anvil
# === Copy protocol_ops and tools ===
COPY --from=build /usr/local/bin/protocol_ops /usr/local/bin/protocol_ops
COPY --from=build /usr/local/bin/zksync-os-genesis-gen /usr/local/bin/zksync-os-genesis-gen
COPY --from=build /usr/local/bin/wallets-gen /usr/local/bin/wallets-gen

# === Set new WORKDIR and copy artifacts to /contracts/ ===
WORKDIR /contracts
COPY --from=build /contracts/configs /contracts/configs
COPY --from=build /contracts/l1-contracts /contracts/l1-contracts
COPY --from=build /contracts/l2-contracts /contracts/l2-contracts
COPY --from=build /contracts/system-contracts /contracts/system-contracts
COPY --from=build /contracts/da-contracts /contracts/da-contracts
COPY --from=build /contracts/lib /contracts/lib
COPY --from=build /contracts/node_modules /contracts/node_modules
COPY --from=build /contracts/package.json /contracts/package.json
COPY --from=build /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json
COPY --from=build /contracts/SystemConfig.json /contracts/SystemConfig.json

# Disable foundry-zksync telemetry
RUN mkdir -p /etc/xdg/zksync-tooling && \
    echo '{"enabled":false,"instance_id":"00000000-0000-0000-0000-000000000000","created_at":"2024-01-01T00:00:00Z","config_path":null}' \
    > /etc/xdg/zksync-tooling/telemetry.json

# Sanity
RUN forge --version && cast --version && anvil --version && protocol_ops --help && \
    zksync-os-genesis-gen --help && wallets-gen --help && node --version && yarn --version
