// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @dev Chain-local bookkeeping of an asset's L1 <-> L2 flows while the chain settles on L1.
/// `preTrackingTotalSupply` is the same quantity as `totalSuccessfulDepositsFromL1 -
/// totalWithdrawalsToL1`, accumulated before the tracking started. It is meaningful exactly when
/// the vault's `isAssetTracked` is set for the asset: on L2 every writer that marks an asset
/// tracked records the baseline in the same call, so no separate saved-flag is needed. The
/// baseline's exact conventions are defined at the storage site — see
/// `L2NativeTokenVault.assetBookkeeping`.
struct L2AssetBookkeepingInfo {
    uint256 preTrackingTotalSupply;
    uint256 totalWithdrawalsToL1;
    uint256 totalSuccessfulDepositsFromL1;
}
