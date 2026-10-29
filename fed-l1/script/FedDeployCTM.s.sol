// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {ChainCreationParamsConfig} from "deploy-scripts/utils/Types.sol";

/// @notice `DeployCTMScript` with the genesis batch values taken from the environment instead of
///         `configs/genesis/zksync-os/latest.json`, for chains that run a custom state transition.
/// @dev    - FED_GENESIS_BATCH_HASH        -> StoredBatchInfo(batch 0).batchHash (the release's `genesisBatchHash`).
///           Unset/zero keeps ZKsync OS's `genesis_root` from latest.json.
///         - FED_GENESIS_ROLLUP_LEAF_INDEX -> StoredBatchInfo(batch 0).indexRepeatedStorageChanges (default 0).
///         The batch-0 `commitment` is not configurable: `ChainTypeManager.storedBatchZero` hard-codes
///         `GENESIS_BATCH_COMMITMENT` (= bytes32(1)).
contract FedDeployCTMScript is DeployCTMScript {
    function getChainCreationParamsConfig(
        string memory _config
    ) internal override returns (ChainCreationParamsConfig memory params) {
        params = super.getChainCreationParamsConfig(_config);
        bytes32 genesisBatchHash = vm.envOr("FED_GENESIS_BATCH_HASH", bytes32(0));
        if (genesisBatchHash != bytes32(0)) {
            params.genesisRoot = genesisBatchHash;
        }
        params.genesisRollupLeafIndex = vm.envOr("FED_GENESIS_ROLLUP_LEAF_INDEX", uint256(0));
    }
}
