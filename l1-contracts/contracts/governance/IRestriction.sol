// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Call} from "./Common.sol";

/// @title Restriction contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRestriction {
    /// @notice Ensures that the invoker has the required role to call the function.
    /// @param _call The call data.
    /// @param _invoker The address of the invoker.
    function validateCall(Call calldata _call, address _invoker) external view;
}
