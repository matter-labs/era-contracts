# syntax=docker/dockerfile:1.6

########################################
# 1) Build
########################################
FROM debian:bookworm-slim AS build

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH \
    YARN_CACHE_FOLDER=/tmp/yarn-cache

# Build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git bash coreutils openssl jq xz-utils gnupg && \
    rm -rf /var/lib/apt/lists/*

# Node 18.20.8 + Yarn 1.22.19
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs=18.20.8-* \
 && npm i -g yarn@1.22.19 \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# Foundry ZKSync (pinned)
RUN curl -LO https://github.com/matter-labs/foundry-zksync/releases/download/nightly-ae913af65381734ad46c044a9495b67310bc77c4/foundry_nightly_linux_amd64.tar.gz \
 && tar zxf foundry_nightly_linux_amd64.tar.gz -C /usr/local/bin/ \
 && chmod +x /usr/local/bin/forge /usr/local/bin/cast \
 && rm foundry_nightly_linux_amd64.tar.gz

# Copy sources
WORKDIR /contracts
COPY . /contracts
RUN yarn install --frozen-lockfile

# Clean
RUN forge clean --root da-contracts
RUN yarn --cwd l1-contracts clean
RUN forge clean --root l1-contracts
RUN yarn --cwd l2-contracts clean
RUN forge clean --root l2-contracts
RUN yarn --cwd system-contracts clean
RUN forge clean --root system-contracts

# Compile contracts
RUN yarn --cwd da-contracts build:foundry
RUN yarn --cwd l1-contracts build:foundry
RUN yarn --cwd l2-contracts build:foundry
RUN yarn --cwd system-contracts build:foundry

# Check hashes
RUN yarn calculate-hashes:check

# Remove node_modules
RUN rm -rf node_modules

########################################
# 2) Runtime
########################################
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH

# Minimal runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates bash openssl jq && \
    rm -rf /var/lib/apt/lists/*

# forge/cast
COPY --from=build /usr/local/bin/forge /usr/local/bin/forge
COPY --from=build /usr/local/bin/cast  /usr/local/bin/cast

WORKDIR /contracts
COPY --from=build /contracts/l1-contracts /contracts/l1-contracts
COPY --from=build /contracts/l2-contracts /contracts/l2-contracts
COPY --from=build /contracts/system-contracts /contracts/system-contracts
COPY --from=build /contracts/da-contracts /contracts/da-contracts
COPY --from=build /contracts/lib /contracts/lib
COPY --from=build /contracts/AllContractsHashes.json /contracts/AllContractsHashes.json
COPY --from=build /contracts/SystemConfig.json /contracts/SystemConfig.json

# Sanity
RUN forge --version
