// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {console2} from "forge-std/Script.sol";

import {EmergencyStageUpgradeCalldata} from "./EmergencyStageUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {ISafe} from "../interfaces/ISafe.sol";
import {EMERGENCY_UPGRADE_SALT} from "../utils/Utils.sol";

/// @notice FORK-ONLY proof that the handler's EmergencyUpgradeBoard accepts the approved-hash route
///         {EmergencyStageUpgradeCalldata} emits: the owner EOA pre-approves every Safe message hash
///         (`vm.prank` stands in for it), then the board executes a proposal with an EMPTY call list,
///         which isolates the signature path from any upgrade's calls.
contract VerifyEmergencyApproveHash is EmergencyStageUpgradeCalldata {
    /// @param _protocolUpgradeHandler The handler whose board is checked.
    function run(address _protocolUpgradeHandler) external {
        EmergencyProposal memory proposal = buildEmergencyProposal(
            IProtocolUpgradeHandler(_protocolUpgradeHandler),
            new IProtocolUpgradeHandler.Call[](0)
        );
        console2.log("Owner EOA (must be your MetaMask account):", proposal.owner);

        for (uint256 i = 0; i < proposal.approvals.length; ++i) {
            vm.prank(proposal.owner);
            ISafe(proposal.approvals[i].safe).approveHash(proposal.approvals[i].safeMessageHash);
        }

        proposal.board.executeEmergencyUpgrade({
            _calls: proposal.calls,
            _salt: EMERGENCY_UPGRADE_SALT,
            _guardiansSignatures: proposal.guardiansSignatures,
            _securityCouncilSignatures: proposal.securityCouncilSignatures,
            _zkFoundationSignatures: proposal.zkFoundationSignatures
        });
        console2.log("SUCCESS: board accepted approved-hash markers; emergency upgrade executed (empty calls).");
    }
}
