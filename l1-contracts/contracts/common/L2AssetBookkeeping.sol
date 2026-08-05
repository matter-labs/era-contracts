// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @dev A recorded total-supply value and whether it was recorded (so a genuine zero is
/// distinguishable from "never saved").
struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

/// @dev L2-side accounting of L1 <-> L2 flows while this chain settles on L1.
struct InteropL2Info {
    uint256 totalWithdrawalsToL1;
    uint256 totalSuccessfulDepositsFromL1;
}
