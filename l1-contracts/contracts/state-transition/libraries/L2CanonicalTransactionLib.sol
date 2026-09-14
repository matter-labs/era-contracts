// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "../../common/Messaging.sol";

/// @notice Helpers for constructing zero-initialised L2 canonical transactions.
/// @dev Shared between runtime contracts (`CTMUpgradeComposer`) and deploy scripts (`UpgradeHelperLib`)
/// to avoid manual zero-struct assembly that can desync when fields change.
library L2CanonicalTransactionLib {
    /// @notice The all-zero transaction (`txType == 0`), which `BaseZkSyncUpgrade` treats as "no L2
    ///         protocol upgrade transaction".
    function emptyL2CanonicalTransaction() internal pure returns (L2CanonicalTransaction memory) {
        return
            L2CanonicalTransaction({
                txType: 0,
                from: 0,
                to: 0,
                gasLimit: 0,
                gasPerPubdataByteLimit: 0,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                paymaster: 0,
                nonce: 0,
                value: 0,
                reserved: [uint256(0), 0, 0, 0],
                data: "",
                signature: "",
                factoryDeps: new uint256[](0),
                paymasterInput: "",
                reservedDynamic: ""
            });
    }
}
