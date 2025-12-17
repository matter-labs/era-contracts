// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @title SimpleExecutor
 * @notice A minimal contract that forwards arbitrary calldata to a target contract.
 *         Useful as an EIP-7702 execution target.
 */
contract SimpleExecutor {
    /**
     * @notice Execute an arbitrary call on a target contract.
     * @param target The address to call.
     * @param value Amount of ETH to send with the call.
     * @param data Calldata to forward.
     * @return success Whether the call succeeded.
     * @return result Raw return data from the call.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bool success, bytes memory result) {
        (success, result) = target.call{value: value}(data);
    }

    // Allow the contract to receive ETH
    receive() external payable {}
}
