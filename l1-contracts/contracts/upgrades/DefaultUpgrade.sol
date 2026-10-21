// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {ProposedUpgradeLib} from "../state-transition/libraries/ProposedUpgradeLib.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract DefaultUpgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public virtual override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Runs an upgrade that only moves the chain to `_newProtocolVersion` and, with it, to the verifier
    /// the CTM stores for that version.
    /// @dev Takes the version rather than a whole {ProposedUpgrade} so that the all-zero struct is built here
    /// instead of in the {ChainTypeManager}, which is close to the contract size limit.
    /// @param _newProtocolVersion The protocol version to upgrade to.
    function upgradeVerifierOnly(uint256 _newProtocolVersion) external virtual returns (bytes32) {
        return upgrade(ProposedUpgradeLib.emptyProposedUpgrade(_newProtocolVersion));
    }
}
