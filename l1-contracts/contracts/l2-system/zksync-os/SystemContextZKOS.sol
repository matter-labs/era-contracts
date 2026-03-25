// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContextLib, SystemContextStorage} from "../SystemContextLib.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice ZK OS-specific SystemContext contract.
 * @dev Minimal implementation: only manages the settlement layer chain ID.
 * Delegates to SystemContextLib for the shared implementation.
 */
contract SystemContextZKOS {
    using SystemContextLib for SystemContextStorage;

    modifier onlyBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Returns the storage pointer anchored at slot 0.
    function _sc() private pure returns (SystemContextStorage storage $) {
        assembly {
            $.slot := 0
        }
    }

    /// @notice The chainId of the settlement layer.
    function currentSettlementLayerChainId() external view returns (uint256) {
        return _sc().currentSettlementLayerChainId;
    }

    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        _sc().setSettlementLayerChainId(_newSettlementLayerChainId);
    }
}
