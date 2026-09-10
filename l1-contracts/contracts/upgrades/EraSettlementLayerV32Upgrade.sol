// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {MustBeEraChain} from "../common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @title EraSettlementLayerV32Upgrade
/// @dev V32 upgrade for Era chains, installing the multi-proof gate.
/// @custom:security-contact security@matterlabs.dev
contract EraSettlementLayerV32Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        // Checked before any work: a ZKsync OS chain routed here is a wiring mistake, and the base
        // upgrade would otherwise fail it later with a less specific error.
        if (s.zksyncOS) {
            revert MustBeEraChain();
        }

        // The chain comes out of this cut requiring both proof systems, since `disabledProofSystems`
        // is new in this version and reads zero. A batch committed before the cut carries no
        // Airbender commitment and the gate would refuse it, so none may be in flight.
        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        super.upgrade(_proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
