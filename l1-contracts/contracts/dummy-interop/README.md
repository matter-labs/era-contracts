# L2->L1 interop demo

run:

export L1_RPC_URL=...
export PRIVATE_KEY=

## To deploy the contracts

``
forge script ./contracts/dummy-interop/DeployContracts.s.sol --legacy --ffi --rpc-url=https://zksync-os-testnet-alpha.zksync.dev/ --slow --skip-simulation --broadcast --private-key=$PRIVATE_KEY --sig "run(string, string)" $L1_RPC_URL https://zksync-os-testnet-alpha.zksync.dev/
``

``
forge verify-contract ADDRESS L1InteropHandler -r $L1_RPC_URL --etherscan-api-key 7PSZZ1PB7WGUHQ5JI51QXI1JIK3REFTVTT
``

``
forge verify-contract ADDRESS L2InteropCenter --verifier=custom --verifier-url "https://block-explorer-api.zksync-os-testnet-alpha.zksync.dev/api"
``

Currently contracts are hardcodeded in the deploy script, if new ones are deployed the script has to be updated.

## Send withdrawals

``
forge script ./contracts/dummy-interop/DeployContracts.s.sol --legacy --ffi --rpc-url=https://zksync-os-testnet-alpha.zksync.dev/ --slow --skip-simulation --broadcast --private-key=$PRIVATE_KEY --sig "withdrawTokenAndSendBundleToL1(string, string)" $L1_RPC_URL "https://zksync-os-testnet-alpha.zksync.dev/l2_rpc"
``

This outputs two hashes: WITHDRAW_MSG_HASH and BUNDLE_MSG_HASH.

## Finalize withdrawals

These might have to be called twice to give enough time for the batch to be executed.

``
    forge script ./contracts/dummy-interop/DeployContracts.s.sol --legacy --ffi --rpc-url=https://zksync-os-testnet-alpha.zksync.dev/ --slow --skip-simulation --broadcast --private-key=$PRIVATE_KEY --sig "finalizeTokenWithdrawals(string, string)" $L1_RPC_URL https://zksync-os-testnet-alpha.zksync.dev/ {WITHDRAW_MSG_HASH} {BUNDLE_MSG_HASH}
``

``
    forge script ./contracts/dummy-interop/DeployContracts.s.sol --legacy --ffi --rpc-url=https://zksync-os-testnet-alpha.zksync.dev/ --slow --skip-simulation --broadcast --private-key=$PRIVATE_KEY --sig "finalizeBundleWithdrawals(string, string)" $L1_RPC_URL https://zksync-os-testnet-alpha.zksync.dev/ {WITHDRAW_MSG_HASH} {BUNDLE_MSG_HASH}
``
