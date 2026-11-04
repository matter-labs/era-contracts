// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IPriorityOpLowerBound} from "./IPriorityOpLowerBound.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {
    BaseTokenPreV31TotalSupplyNotSet,
    LowerBoundNotRecorded,
    PriorityQueueNotReady
} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title V32UpgradeZKsyncOS
/// @notice The v32-specific per-chain upgrade: {DefaultUpgradeZKsyncOS} plus the v31 base-token
/// backfill prerequisite that only this upgrade needs (v32 removes the backfill's L2 entry point).
contract V32UpgradeZKsyncOS is DefaultUpgradeZKsyncOS {
    /// @notice Standalone registry of per-chain priority-op lower bounds; see `upgrade` below.
    IPriorityOpLowerBound public immutable PRIORITY_OP_LOWER_BOUND;

    constructor(IPriorityOpLowerBound _priorityOpLowerBound) {
        PRIORITY_OP_LOWER_BOUND = _priorityOpLowerBound;
    }

    /// @inheritdoc DefaultUpgradeZKsyncOS
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        // The pre-v32 base-token total supply must have been backfilled on v31, and — since the flag
        // below is set eagerly when the backfill service transaction is *requested* while this release
        // removes its L2 entry point — the transaction must also have *executed*.
        // `PRIORITY_OP_LOWER_BOUND` pins (permissionlessly, while the flag is already set) a priority-op
        // count that includes the backfill; requiring all ops below it to be processed proves execution
        // without demanding an empty — and therefore griefable — priority queue.
        require(s.baseTokenHasTotalSupply, BaseTokenPreV31TotalSupplyNotSet());
        require(PRIORITY_OP_LOWER_BOUND.recorded(address(this)), LowerBoundNotRecorded());
        require(
            IGetters(address(this)).getFirstUnprocessedPriorityTx() >=
                PRIORITY_OP_LOWER_BOUND.lowerBound(address(this)),
            PriorityQueueNotReady()
        );

        return super.upgrade(_proposedUpgrade);
    }
}
