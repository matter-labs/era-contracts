# Script to recompile and recreate the hashes for the contracts.
# source ./recompute_hashes.sh


# Update submodules (just in case)
git submodule update --init --recursive


# Cleanup everything and recompile
pushd da-contracts && \
forge clean && popd && \
pushd l1-contracts && \
yarn clean && forge clean && popd && \
pushd l2-contracts && \
yarn clean && forge clean && popd && \
pushd system-contracts && \
yarn clean && forge clean && popd && \
pushd da-contracts && \
yarn build:foundry && popd && \
pushd l1-contracts && \
yarn build:foundry && popd && \
pushd l2-contracts && \
yarn build:foundry && popd && \
pushd system-contracts && \
yarn build:foundry && popd && \
yarn calculate-hashes:fix
