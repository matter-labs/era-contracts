# syntax=docker/dockerfile:1.6

ARG FOUNDRY_ARCH=linux_amd64
ARG FOUNDRY_TAG=nightly-807f47ace7cdd90eed7190dc4481952cfaa25938
ARG NODE_MAJOR=18
ARG NODE_VERSION=18.18.0
ARG RUST_TARGET=x86_64-unknown-linux-gnu
ARG RUST_TOOLCHAIN=nightly-2024-09-01
ARG YARN_VERSION=1.22.19

########################################
# 1) Builder: produce artifacts
########################################
FROM debian:bookworm-slim AS build

ARG FOUNDRY_ARCH
ARG FOUNDRY_TAG
ARG NODE_MAJOR
ARG NODE_VERSION
ARG RUST_TARGET
ARG RUST_TOOLCHAIN
ARG YARN_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/bin:$PATH \
    YARN_CACHE_FOLDER=/tmp/yarn-cache

# Build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git bash coreutils openssl jq xz-utils gnupg \
      build-essential pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Node + Yarn
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs=${NODE_VERSION}-* \
 && npm i -g yarn@${YARN_VERSION} \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# Foundry
RUN curl -L -o /tmp/foundry.tgz https://github.com/matter-labs/foundry-zksync/releases/download/${FOUNDRY_TAG}/foundry_zksync_nightly_${FOUNDRY_ARCH}.tar.gz \
 && tar zxf /tmp/foundry.tgz -C /usr/local/bin/ \
 && chmod +x /usr/local/bin/forge /usr/local/bin/cast \
 && rm /tmp/foundry.tgz

# === Install Rust ===
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain ${RUST_TOOLCHAIN}

# === Install target ===
RUN rustup target add ${RUST_TARGET}

# === Copy all source code and install dependencies ===
WORKDIR /contracts
COPY . /contracts

# === Build protocol_cli ===
WORKDIR /contracts/protocol_cli
RUN cargo build --bin protocol_cli --target ${RUST_TARGET}

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

# === Remove node_modules ===
RUN rm -rf node_modules

########################################
# 2) Runtime: sources + artifacts
########################################
FROM debian:bookworm-slim

# === Pass build arg for copying the correct binary ===
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH

# Minimal runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates bash openssl jq && \
    rm -rf /var/lib/apt/lists/*

# === Copy foundry binaries from build stage ===
COPY --from=build /usr/local/bin/forge /usr/local/bin/forge
COPY --from=build /usr/local/bin/cast  /usr/local/bin/cast
# === Copy the new protocol_cli binary ===
COPY --from=build /contracts/protocol_cli/target/release/protocol_cli /usr/local/bin/protocol_cli

# === Set new WORKDIR and copy artifacts to /contracts/ ===
WORKDIR /contracts
COPY --from=build /contracts/etc /contracts/etc
COPY --from=build /contracts/l1-contracts /contracts/l1-contracts
COPY --from=build /contracts/l2-contracts /contracts/l2-contracts
COPY --from=build /contracts/system-contracts /contracts/system-contracts
COPY --from=build /contracts/da-contracts /contracts/da-contracts
COPY --from=build /contracts/lib /contracts/lib
COPY --from=build /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json
COPY --from=build /contracts/SystemConfig.json /contracts/SystemConfig.json

# Sanity
RUN forge --version && cast --version && protocol_cli --help
