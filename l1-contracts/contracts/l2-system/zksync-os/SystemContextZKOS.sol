// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContextBase} from "../SystemContextBase.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice ZK OS-specific SystemContext contract.
 * @dev Minimal implementation: only manages the settlement layer chain ID using the shared
 * helper from SystemContextBase.
 */
contract SystemContextZKOS is SystemContextBase {
    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        _setSettlementLayerChainId(_newSettlementLayerChainId);
    }
}
