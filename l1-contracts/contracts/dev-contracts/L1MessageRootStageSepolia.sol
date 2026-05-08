// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1MessageRoot} from "../core/message-root/L1MessageRoot.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "../core/message-root/IMessageRoot.sol";
import {NotAllChainsOnL1} from "../core/bridgehub/L1BridgehubErrors.sol";

/// @dev The single chain on the stage Sepolia bridgehub
///      (`0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE`) that is still settling
///      on the stage Gateway (chain 123) at v31 upgrade time.
uint256 constant STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID = 270;

/// @notice Stage Sepolia variant of `L1MessageRoot`. Lives under `dev-contracts/`
///         because it's a one-off, environment-specific impl rather than a
///         canonical L1 contract.
///
/// @dev Stage's Era chain (270) hasn't been migrated back from the stage Gateway
///      (chain 123) at v31 upgrade time. The canonical `_v31InitializeInner`
///      requires every registered chain to be on L1, so the upgrade would revert
///      on stage. This variant skips chain 270 specifically; the chain stamps its
///      own slot via `saveV31UpgradeChainBatchNumber` once it migrates back.
///      Selected by `CoreUpgrade_v31` when the upgrade input opts in.
contract L1MessageRootStageSepolia is L1MessageRoot {
    constructor(
        address _bridgehub,
        uint256 _eraGatewayChainId,
        address _chainAssetHandler
    ) L1MessageRoot(_bridgehub, _eraGatewayChainId, _chainAssetHandler) {}

    function _v31InitializeInner(uint256[] memory _allZKChains) internal override {
        uint256 allZKChainsLength = _allZKChains.length;
        for (uint256 i = 0; i < allZKChainsLength; ++i) {
            uint256 chainId = _allZKChains[i];
            if (chainId == STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID) {
                continue;
            }
            require(IBridgehubBase(_bridgehub()).settlementLayer(chainId) == block.chainid, NotAllChainsOnL1());
            v31UpgradeChainBatchNumber[chainId] = V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE;
        }
    }
}
