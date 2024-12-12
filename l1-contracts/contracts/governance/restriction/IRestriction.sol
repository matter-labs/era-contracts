// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Call} from "../Common.sol";

/// @dev The magic value that has to be returned by the `getSupportsRestrictionMagic`
bytes32 constant RESTRICTION_MAGIC = keccak256("Restriction");

/// @title Restriction contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRestriction {
    /// @notice A method used to check that the contract supports this interface.
    /// @return Returns the `RESTRICTION_MAGIC`
    function getSupportsRestrictionMagic() external view returns (bytes32);

    /// @notice Ensures that the invoker has the required role to call the function.
    /// @param _call The call data.
    /// @param _invoker The address of the invoker.
    function validateCall(Call calldata _call, address _invoker) external view;
}
