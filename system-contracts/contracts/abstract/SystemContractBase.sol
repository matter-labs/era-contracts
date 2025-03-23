// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, L2_INTEROP_HANDLER, L2_INTEROP_CENTER, FORCE_DEPLOYER, L2_STANDARD_TRIGGER_ACCOUNT_ADDR} from "../Constants.sol";
import {SystemCallFlagRequired, Unauthorized, CallerMustBeSystemContract, CallerMustBeBootloader, CallerMustBeEvmContract, CallerMustBeInteropCenter} from "../SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice An abstract contract that is used to reuse modifiers across the system contracts.
 * @dev Solidity does not allow exporting modifiers via libraries, so
 * the only way to do reuse modifiers is to have a base contract
 * @dev Never add storage variables into this contract as some
 * system contracts rely on this abstract contract as on interface!
 */
abstract contract SystemContractBase {
    /// @notice Modifier that makes sure that the method
    /// can only be called via a system call.
    modifier onlySystemCall() {
        if (!SystemContractHelper.isSystemCall() && !SystemContractHelper.isSystemContract(msg.sender)) {
            revert SystemCallFlagRequired();
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called via a system call.
    modifier onlyStandardTriggerAccount() {
        if (msg.sender != L2_STANDARD_TRIGGER_ACCOUNT_ADDR) {
            // revert SystemCallFlagRequired();
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from a system contract.
    modifier onlyCallFromSystemContract() {
        if (!SystemContractHelper.isSystemContract(msg.sender)) {
            revert CallerMustBeSystemContract();
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from a special given address.
    modifier onlyCallFrom(address caller) {
        if (msg.sender != caller) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from the bootloader.
    modifier onlyCallFromBootloader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert CallerMustBeBootloader();
        }
        _;
    }

    /// can only be called from the EVM emulator using system call (unaccessible from EVM environment)
    modifier onlySystemCallFromEvmEmulator() {
        if (!SystemContractHelper.isSystemCallFromEvmEmulator()) {
            revert CallerMustBeEvmContract();
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from the bootloader.
    modifier onlyCallFromBootloaderOrInteropHandler() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS && msg.sender != address(L2_INTEROP_HANDLER)) {
            revert CallerMustBeBootloader();
        }
        _;
    }

    /// @notice Modifier that makes sure that the method
    /// can only be called from the interop center.
    modifier onlyCallFromInteropCenter() {
        if (msg.sender != address(L2_INTEROP_CENTER)) {
            revert CallerMustBeInteropCenter();
        }
        _;
    }
}
