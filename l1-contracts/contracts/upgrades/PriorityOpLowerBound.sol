// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IPriorityOpLowerBound} from "./IPriorityOpLowerBound.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {BaseTokenPreV31TotalSupplyNotSet, LowerBoundAlreadyRecorded} from "../common/L1ContractErrors.sol";

/// @title PriorityOpLowerBound
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Pins, per chain, a priority-op count observed while the chain's pre-v31 base-token
/// total supply was already backfilled (v31 sets that flag when the backfill service
/// transaction is *requested*). The v33 upgrade of a ZKsync OS chain then requires all priority
/// ops below the pinned count to be processed, proving the backfill *executed* on L2 before the
/// upgrade removes its L2 entry point — without demanding an empty (griefable) priority queue.
/// @dev Specific to the v33 upgrade (`V33UpgradeZKsyncOS`) — no default or later upgrade should
/// reference it. A standalone contract: the pin must be readable before the chain's facets are
/// upgraded, so the upgrade references it as an immutable rather than using its own diamond storage.
contract PriorityOpLowerBound is IPriorityOpLowerBound {
    /// @inheritdoc IPriorityOpLowerBound
    mapping(address chain => uint256 bound) public override lowerBound;

    /// @inheritdoc IPriorityOpLowerBound
    /// @dev A separate flag rather than a zero sentinel: a chain created on v31 legitimately has
    /// zero priority ops (its flag comes from DiamondInit, with no backfill to prove) and must
    /// still be able to record and upgrade.
    mapping(address chain => bool isRecorded) public override recorded;

    /// @inheritdoc IPriorityOpLowerBound
    function lowerBoundPriorityOp(address _chain) external override {
        // First call wins: a later caller must not be able to raise the bound and delay the upgrade.
        if (recorded[_chain]) {
            revert LowerBoundAlreadyRecorded();
        }
        if (!IGetters(_chain).baseTokenSupportsTotalSupply()) {
            revert BaseTokenPreV31TotalSupplyNotSet();
        }

        uint256 totalPriorityTxs = IGetters(_chain).getTotalPriorityTxs();
        recorded[_chain] = true;
        lowerBound[_chain] = totalPriorityTxs;
        emit LowerBoundRecorded(_chain, totalPriorityTxs);
    }
}
