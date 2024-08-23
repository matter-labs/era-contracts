// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "../Constants.sol";

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
    // This is for strings
    function printIt(bytes32 toPrint) public {
        assembly {
            function $llvm_NoInline_llvm$_printString(__value) {
                let DEBUG_SLOT_OFFSET := mul(32, 32)
                mstore(add(DEBUG_SLOT_OFFSET, 0x20), 0x00debdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdf)
                mstore(add(DEBUG_SLOT_OFFSET, 0x40), __value)
                mstore(DEBUG_SLOT_OFFSET, 0x4A15830341869CAA1E99840C97043A1EA15D2444DA366EFFF5C43B4BEF299681)
            }
            $llvm_NoInline_llvm$_printString(toPrint)
        }
    }

    // This is for numbers
    function printItNum(uint256 toPrint) public {
        assembly {
            function $llvm_NoInline_llvm$_printString(__value) {
                let DEBUG_SLOT_OFFSET := mul(32, 32)
                mstore(add(DEBUG_SLOT_OFFSET, 0x20), 0x00debdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebdebde)
                mstore(add(DEBUG_SLOT_OFFSET, 0x40), __value)
                mstore(DEBUG_SLOT_OFFSET, 0x4A15830341869CAA1E99840C97043A1EA15D2444DA366EFFF5C43B4BEF299681)
            }
            $llvm_NoInline_llvm$_printString(toPrint)
        }
    }
    /// @notice Modifier that makes sure that the method
    /// can only be called via a system call.
    modifier onlySystemCall() {
        bytes32 toPrint = "PRINT IN MODIFIER";
        printIt(toPrint);
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
}
