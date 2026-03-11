// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title L2ComplexUpgrader
/// @notice EVM-compatible version of the ComplexUpgrader system contract for Anvil testing.
/// @dev Performs delegatecall to upgrade contracts. In production this is a system contract
/// that can only be called by FORCE_DEPLOYER; in tests any caller is allowed.
contract L2ComplexUpgrader {
    /// @notice Execute an upgrade by delegatecalling into the target contract.
    /// @param _delegateTo The contract to delegatecall into.
    /// @param _calldata The calldata for the delegatecall.
    function upgrade(address _delegateTo, bytes calldata _calldata) external payable {
        require(_delegateTo.code.length > 0, "Target has no code");
        (bool success, bytes memory returnData) = _delegateTo.delegatecall(_calldata);
        assembly {
            if iszero(success) {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
