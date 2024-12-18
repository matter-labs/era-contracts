// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Call} from "../Common.sol";
import {IRestriction, RESTRICTION_MAGIC} from "./IRestriction.sol";

/// @title Restriction contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
abstract contract Restriction is IRestriction {
    /// @notice A method used to check that the contract supports this interface.
    /// @return Returns the `RESTRICTION_MAGIC`
    function getSupportsRestrictionMagic() external view returns (bytes32) {
        return RESTRICTION_MAGIC;
    }

    /// @notice Ensures that the invoker has the required role to call the function.
    /// @param _call The call data.
    /// @param _invoker The address of the invoker.
    function validateCall(Call calldata _call, address _invoker) external view virtual;
}
