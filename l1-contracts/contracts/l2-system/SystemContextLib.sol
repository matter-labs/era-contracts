// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/**
 * @notice Storage fields shared between SystemContextEra and SystemContextZKOS.
 * @dev In SystemContextEra this struct is placed at slot 270 (where currentSettlementLayerChainId
 * lived in the original SystemContext.sol), preserving the original storage layout.
 * In SystemContextZKOS it is placed at slot 0.
 */
struct CommonSystemContextStorage {
    uint256 currentSettlementLayerChainId;
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Library implementing the shared settlement-layer chain ID logic for both
 * SystemContextEra and SystemContextZKOS.
 */
library CommonSystemContextLib {
    /// @notice Emitted when the Settlement Layer chain id is modified.
    event SettlementLayerChainIdUpdated(uint256 indexed _newSettlementLayerChainId);

    /// @notice Updates the settlement layer chain ID, calling the chain asset handler and
    /// emitting an event when the value actually changes.
    function setSettlementLayerChainId(
        CommonSystemContextStorage storage $,
        uint256 _newSettlementLayerChainId
    ) internal {
        if ($.currentSettlementLayerChainId != _newSettlementLayerChainId) {
            // slither-disable-next-line reentrancy-no-eth
            IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(
                $.currentSettlementLayerChainId,
                _newSettlementLayerChainId
            );
            $.currentSettlementLayerChainId = _newSettlementLayerChainId;
            emit SettlementLayerChainIdUpdated(_newSettlementLayerChainId);
        }
    }
}
