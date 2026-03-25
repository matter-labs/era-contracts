// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CommonSystemContextLib, CommonSystemContextStorage} from "../SystemContextLib.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice ZK OS-specific SystemContext contract.
 * @dev Minimal implementation: only manages the settlement layer chain ID.
 * The shared setSettlementLayerChainId logic is delegated to CommonSystemContextLib.
 */
contract SystemContextZKOS {
    using CommonSystemContextLib for CommonSystemContextStorage;

    modifier onlyBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Slot 0. Contains currentSettlementLayerChainId.
    CommonSystemContextStorage internal _common;

    /// @notice The chainId of the settlement layer.
    function currentSettlementLayerChainId() external view returns (uint256) {
        return _common.currentSettlementLayerChainId;
    }

    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyBootloader {
        _common.setSettlementLayerChainId(_newSettlementLayerChainId);
    }
}
