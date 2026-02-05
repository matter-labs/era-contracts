// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "./errors/ZKOSContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Contract that stores some of the context variables, that may be either
 * block-scoped, tx-scoped or system-wide.
 */
contract SystemContext {
    /// @notice Emitted when the Settlement Layer chain id is modified.
    /// @param _newSettlementLayerChainId    The new Settlement Layer chain id.
    event SettlementLayerChainIdUpdated(uint256 indexed _newSettlementLayerChainId);

    /// @notice The chainId of the settlement layer.
    /// @notice This value will be deprecated in the future, it should not be used by external contracts.
    uint256 public currentSettlementLayerChainId;

    /// @notice Modifier that makes sure that the method
    /// can only be called from the bootloader.
    modifier onlyCallFromBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyCallFromBootloader {
        if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
            currentSettlementLayerChainId = _newSettlementLayerChainId;
            emit SettlementLayerChainIdUpdated(_newSettlementLayerChainId);
        }
    }
}
