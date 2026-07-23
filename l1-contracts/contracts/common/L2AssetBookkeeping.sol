// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @dev Token supply baseline captured before the token's first tracked bridge operation.
struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

/// @dev L2-side accounting of L1 <-> L2 flows while this chain settles on L1.
struct InteropL2Info {
    uint256 totalWithdrawalsToL1;
    uint256 totalSuccessfulDepositsFromL1;
}
