// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract MulticallWithGas {
    struct Call {
        address to;
        uint256 gasLimit;
        bytes data;
    }

    /// @notice Executes multiple calls in a single transaction, passing a gas limit for each call.
    function aggregate(Call[] calldata calls, bool mustSucceed) external {
        for (uint256 i = 0; i < calls.length; i++) {
            // We ignore failures
            (bool success, bytes memory result) = calls[i].to.call{gas: calls[i].gasLimit}(calls[i].data);
            if (mustSucceed && !success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }
}
