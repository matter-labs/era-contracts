// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @dev Chain-local bookkeeping of an asset's L1 <-> L2 flows while the chain settles on L1.
/// `preTrackingTotalSupply` is the same quantity as `totalSuccessfulDepositsFromL1 -
/// totalWithdrawalsToL1`, accumulated before the tracking started (with `isSaved` marking that the
/// baseline was recorded, so a genuine zero is distinguishable from "never saved"). The baseline's
/// exact conventions are defined at the storage site — see `L2NativeTokenVault.assetBookkeeping`.
struct L2AssetBookkeepingInfo {
    bool isSaved;
    uint256 preTrackingTotalSupply;
    uint256 totalWithdrawalsToL1;
    uint256 totalSuccessfulDepositsFromL1;
}
