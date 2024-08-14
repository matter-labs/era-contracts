// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { Call } from "./Common.sol";

/// @title ChainAdmin contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRestriction {
    function validateCall(Call calldata _call) external view;
}
