// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Upgrade_4844 is BaseZkSyncUpgrade {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        // Check to make sure that the new blob versioned hash address is not the zero address.
        require($(BLOB_VERSIONED_HASH_GETTER_ADDR) != address(0), "b9");

        s.blobVersionedHashRetriever = $(BLOB_VERSIONED_HASH_GETTER_ADDR);

        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
