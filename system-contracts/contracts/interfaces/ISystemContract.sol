// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, FORCE_DEPLOYER} from "../Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice An abstract contract that is used to reuse modifiers across the system contracts.
 * @dev Solidity does not allow exporting modifiers via libraries, so
 * the only way to do reuse modifiers is to have a base contract
 * @dev Never add storage variables into this contract as some
 * system contracts rely on this abstract contract as on interface!
 */
abstract contract ISystemContract {
    /// @notice Modifier that makes sure that the method
    /// can only be called via a system call.
    modifier onlySystemCall() {
        require(
            SystemContractHelper.isSystemCall() || SystemContractHelper.isSystemContract(msg.sender),
            "This method require system call flag"
        );
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from a system contract.
    modifier onlyCallFromSystemContract() {
        require(
            SystemContractHelper.isSystemContract(msg.sender),
            "This method require the caller to be system contract"
        );
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from a special given address.
    modifier onlyCallFrom(address caller) {
        require(msg.sender == caller, "Inappropriate caller");
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from the bootloader.
    modifier onlyCallFromBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS, "Callable only by the bootloader");
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from the L1 force deployer.
    modifier onlyCallFromForceDeployer() {
        require(msg.sender == FORCE_DEPLOYER);
        _;
    }
}
