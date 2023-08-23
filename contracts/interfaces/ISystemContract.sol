// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";

/// @dev Solidity does not allow exporting modifiers via libraries, so
/// the only way to do reuse modifiers is to have a base contract
abstract contract ISystemContract {
    /// @notice Modifier that makes sure that the method
    /// can only be called via a system call.
    modifier onlySystemCall() {
        require(
            SystemContractHelper.isSystemCall() || SystemContractHelper.isSystemContract(msg.sender),
            "This method requires the system call flag"
        );
        _;
    }
}
