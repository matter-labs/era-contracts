// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-length-in-loops

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract that is used as a temporary owner for Ownable2Step contracts until the
/// governance can accept the ownership
contract TransitionaryOwner {
    address public immutable GOVERNANCE_ADDRESS;

    constructor(address _governanceAddress) {
        GOVERNANCE_ADDRESS = _governanceAddress;
    }

    /// @notice Claims that ownership of a contract and transfers it to the governance
    function claimOwnershipAndGiveToGovernance(address target) external {
        Ownable2Step(target).acceptOwnership();
        Ownable2Step(target).transferOwnership(GOVERNANCE_ADDRESS);
    }
}
