// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1MessageRoot} from "../core/message-root/L1MessageRoot.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "../core/message-root/IMessageRoot.sol";
import {NotAllChainsOnL1} from "../core/bridgehub/L1BridgehubErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Test-only `L1MessageRoot` that can stamp the v31 placeholder into
///         `v31UpgradeChainBatchNumber`, the way v31's `initializeL1V31Upgrade` did.
/// @dev That initializer was removed in v33 — no ecosystem can call it any more, since the proxy has
///      consumed reinitializer version 2 either during its v31 upgrade or through `initialize()`. Chains
///      whose per-chain v31 upgrade has not landed yet still carry the placeholder in inherited storage,
///      though, so `saveV31UpgradeChainBatchNumber` remains live and its tests need a way to reach that
///      state. Deploying this behind a proxy reproduces it without touching storage slots directly.
contract L1MessageRootDev is L1MessageRoot {
    constructor(
        address _bridgehub,
        uint256 _eraGatewayChainId,
        address _chainAssetHandler
    ) L1MessageRoot(_bridgehub, _eraGatewayChainId, _chainAssetHandler) {}

    /// @notice Stamps the v31 placeholder for every registered chain, exactly as v31 did.
    function stampV31Placeholders() external reinitializer(2) {
        uint256[] memory allZKChains = IBridgehubBase(BRIDGE_HUB).getAllZKChainChainIDs();
        uint256 allZKChainsLength = allZKChains.length;
        for (uint256 i = 0; i < allZKChainsLength; ++i) {
            require(IBridgehubBase(_bridgehub()).settlementLayer(allZKChains[i]) == block.chainid, NotAllChainsOnL1());
            v31UpgradeChainBatchNumber[allZKChains[i]] = V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE;
        }
    }
}
