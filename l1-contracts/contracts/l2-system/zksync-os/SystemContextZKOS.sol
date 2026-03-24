// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContextBase} from "../SystemContextBase.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice ZK OS-specific SystemContext contract.
 * @dev Minimal implementation: only manages the settlement layer chain ID.
 */
contract SystemContextZKOS is SystemContextBase {
    /// @notice Emitted when the Settlement Layer chain id is modified.
    event SettlementLayerChainIdUpdated(uint256 indexed _newSettlementLayerChainId);

    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
            // slither-disable-next-line reentrancy-no-eth
            IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(
                currentSettlementLayerChainId,
                _newSettlementLayerChainId
            );
            currentSettlementLayerChainId = _newSettlementLayerChainId;
            emit SettlementLayerChainIdUpdated(_newSettlementLayerChainId);
        }
    }
}
