// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IFinalizeUpgrade
/// @notice Interface for FinalizeUpgrade.s.sol script
interface IFinalizeUpgrade {
    function initChains(address bridgehub, uint256[] calldata chains) external;

    function initTokens(
        address payable l1NativeTokenVault,
        address[] calldata tokens,
        uint256[] calldata chains
    ) external;
}
