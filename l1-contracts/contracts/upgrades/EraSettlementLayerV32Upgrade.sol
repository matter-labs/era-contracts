// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "../common/Config.sol";
import {MustBeEraChain} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @title EraSettlementLayerV32Upgrade
/// @dev V32 upgrade for Era chains. The upgrade that installs the multi-proof gate must also mask
/// its Airbender lane, in the same diamond cut.
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

        super.upgrade(_proposedUpgrade);

        // `disabledProofSystems` is new in this version, so it reads zero on a chain arriving here,
        // and zero requires both proof systems. Batches committed before the cut carry no Airbender
        // commitment, so the gate would refuse them, and `Committer` would start demanding a heap
        // hash the sequencer is not sending — the chain would stop proving and stop committing.
        //
        // Set in the initializer rather than in governance calldata so the mask cannot be left out
        // of an upgrade bundle. The admin brings the lane up afterwards with `setProofSystemStatus`,
        // on a drained pipeline.
        s.disabledProofSystems = AIRBENDER_PROOF_SYSTEM_DISABLED;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
