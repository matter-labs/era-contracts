// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {Call} from "contracts/governance/Common.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
library UpgradeUtils {
    /// @notice Merge array of Call arrays into single Call array
    function mergeCallsArray(Call[][] memory a) public pure returns (Call[] memory result) {
        uint256 resultLength;

        for (uint256 i; i < a.length; i++) {
            resultLength += a[i].length;
        }

        result = new Call[](resultLength);

        uint256 counter;
        for (uint256 i; i < a.length; i++) {
            for (uint256 j; j < a[i].length; j++) {
                result[counter] = a[i][j];
                counter++;
            }
        }
    }
}
