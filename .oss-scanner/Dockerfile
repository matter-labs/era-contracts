# Build for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner, projects/era-contracts), which builds
# main with this file: a Yarn workspace of Foundry projects (l1-contracts, l2-contracts, system-contracts,
# da-contracts) built with foundry-zksync, dependencies in git submodules. Mirrors
# .github/workflows/l1-contracts-ci.yaml: when CI bumps Node, foundry-zksync or a compiler, bump them here too.
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq xz-utils build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

# Node 18.18.0 (.nvmrc) and Yarn 1.
RUN arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" \
    && curl -fsSL "https://nodejs.org/dist/v18.18.0/node-v18.18.0-linux-${arch}.tar.xz" \
       | tar -xJ -C /usr/local --strip-components=1 \
    && npm install -g yarn@1.22.19 \
    && npm cache clean --force

# foundry-zksync at the nightly CI pins: forge and cast for both EVM and EraVM (--zksync) builds. Tests shell out to
# cast and node via ffi.
RUN curl -fsSL "https://github.com/matter-labs/foundry-zksync/releases/download/nightly-ae913af65381734ad46c044a9495b67310bc77c4/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz" \
       | tar -xz -C /usr/local/bin forge cast \
    && forge --version

COPY . /src
WORKDIR /src

# lib/* are submodules; the scanner's clone is not recursive.
RUN git submodule update --init --recursive

# Plain `yarn install`, as CI runs it, so a lockfile that CI accepts cannot break this build.
RUN yarn install

# Compile while the network is up; this fetches solc 0.8.28, zksolc 1.5.11 and the EraVM solc. build:foundry compiles
# da-contracts for EVM, l2-contracts and system-contracts for EraVM, and l1-contracts for both, its tests for EVM only.
# l1-contracts tests read the other packages' artifacts, so all four are built.
RUN yarn --cwd da-contracts build:foundry
RUN yarn --cwd l1-contracts build:foundry
RUN yarn --cwd l2-contracts build:foundry
RUN yarn --cwd system-contracts build:foundry

# Nothing below this line, or in the scan, may download a compiler.
ENV FOUNDRY_OFFLINE=true

# Offline from here, and these must succeed: the setup scripts the L1 tests run, and compiling the EraVM test sets that
# `yarn test:zkfoundry` and l2-contracts' `yarn test:foundry` select (`forge test --list` compiles without running).
RUN cd l1-contracts \
    && forge script --sig 0x2dd0ebe3 DeployCTMScript --ffi \
    && forge script --sig 'releaseConfigLock()' ConfigSemaphore \
    && forge test --zksync --match-path 'test/foundry/l2/*' --list > /dev/null \
    && cd ../l2-contracts \
    && forge test --zksync --list > /dev/null

# Smoke-test the suites as CI runs them. Test failures do not fail the build.
RUN (cd l1-contracts && timeout 1200 yarn test:foundry \
      || echo "WARNING: l1-contracts yarn test:foundry reported failures or timed out") \
 && (cd l1-contracts && timeout 1200 yarn test:zkfoundry \
      || echo "WARNING: l1-contracts yarn test:zkfoundry reported failures or timed out") \
 && (cd l2-contracts && timeout 600 yarn test:foundry \
      || echo "WARNING: l2-contracts yarn test:foundry reported failures or timed out")

# The L1 test runs above rewrite or delete l1-contracts/snapshots/Executor.json (forge gas snapshots). Start the scan
# from a tree identical to HEAD, so a patch carries only its own changes.
RUN git checkout -- .
