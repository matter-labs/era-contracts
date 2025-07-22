// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "../common/Config.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {L2_CHAIN_ASSET_HANDLER} from "../common/l2-helpers/L2ContractAddresses.sol";

error PriorityQueueNotReady();

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L1V30Upgrade is BaseZkSyncUpgrade {

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        uint256 l1ChainId = IBridgehub(s.bridgehub).L1_CHAIN_ID();
        /// This is called on the GW.
        if (block.chainid != l1ChainId) {
            L2_CHAIN_ASSET_HANDLER.setMigrationNumberForV30(s.chainId);
        }
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
