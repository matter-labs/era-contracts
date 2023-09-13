// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../../common/libraries/UncheckedMath.sol";
import "../../chain-interfaces/IProofDiamondCut.sol";
import "../../../common/libraries/Diamond.sol";
import "../../Config.sol";
import "./ProofChainBase.sol";

/// @title DiamondCutFacet - contract responsible for the management of upgrades.
/// @author Matter Labs
contract ProofDiamondCutFacet is ProofChainBase, IProofDiamondCut {
    using UncheckedMath for uint256;

    string public constant getName = "DiamondCutFacet";

    modifier upgradeProposed() {
        require(chainStorage.upgrades.state != ProofUpgradeState.None, "a3"); // Proposal doesn't exist
        _;
    }

    modifier noUpgradeProposed() {
        require(chainStorage.upgrades.state == ProofUpgradeState.None, "a8"); // Proposal already exists
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE PROPOSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a fully transparent upgrade, providing upgrade data on-chain
    /// @notice The governor will be able to execute the proposal either
    /// - With a `UPGRADE_NOTICE_PERIOD` timelock on its own
    /// - With security council approvals instantly
    /// @dev Only the current governor can propose an upgrade
    /// @param _diamondCut The diamond cut parameters will be executed with the upgrade
    function proposeTransparentUpgrade(Diamond.DiamondCutData calldata _diamondCut, uint40 _proposalId)
        external
        onlyGovernor
        noUpgradeProposed
    {
        // Set the default value for proposal salt, since the proposal is fully transparent it doesn't change anything
        bytes32 proposalSalt;
        uint40 expectedProposalId = chainStorage.upgrades.currentProposalId + 1;
        // Input proposal ID should be equal to the expected proposal id
        require(_proposalId == expectedProposalId, "yb");
        chainStorage.upgrades.proposedUpgradeHash = upgradeProposalHash(_diamondCut, expectedProposalId, proposalSalt);
        chainStorage.upgrades.proposedUpgradeTimestamp = uint40(block.timestamp);
        chainStorage.upgrades.currentProposalId = expectedProposalId;
        chainStorage.upgrades.state = ProofUpgradeState.Transparent;

        emit ProposeTransparentUpgrade(_diamondCut, expectedProposalId, proposalSalt);
    }

    /// @notice Propose "shadow" upgrade, upgrade data is not publishing on-chain
    /// @notice The governor will be able to execute the proposal only:
    /// - With security council approvals instantly
    /// @dev Only the current governor can propose an upgrade
    /// @param _proposalHash Upgrade proposal hash (see `upgradeProposalHash` function)
    /// @param _proposalId An expected value for the current proposal Id
    function proposeShadowUpgrade(bytes32 _proposalHash, uint40 _proposalId) external onlyGovernor noUpgradeProposed {
        require(_proposalHash != bytes32(0), "mi");

        chainStorage.upgrades.proposedUpgradeHash = _proposalHash;
        chainStorage.upgrades.proposedUpgradeTimestamp = uint40(block.timestamp); // Safe to cast
        chainStorage.upgrades.state = ProofUpgradeState.Shadow;

        uint256 currentProposalId = chainStorage.upgrades.currentProposalId;
        // Expected proposal ID should be one more than the current saved proposal ID value
        require(_proposalId == currentProposalId.uncheckedInc(), "ya");
        chainStorage.upgrades.currentProposalId = _proposalId;

        emit ProposeShadowUpgrade(_proposalId, _proposalHash);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE CANCELING
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancel the proposed upgrade
    /// @dev Only the current governor can remove the proposal
    /// @param _proposedUpgradeHash Expected upgrade hash value to be canceled
    function cancelUpgradeProposal(bytes32 _proposedUpgradeHash) external onlyGovernor upgradeProposed {
        bytes32 currentUpgradeHash = chainStorage.upgrades.proposedUpgradeHash;
        // Soft check that the governor is not mistaken about canceling proposals
        require(_proposedUpgradeHash == currentUpgradeHash, "rx");

        _resetProposal();
        emit CancelUpgradeProposal(chainStorage.upgrades.currentProposalId, currentUpgradeHash);
    }

    /*//////////////////////////////////////////////////////////////
                            SECURITY COUNCIL
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves the instant upgrade by the security council
    /// @param _upgradeProposalHash The upgrade proposal hash that security council members want to approve. Needed to prevent unintentional approvals, including reorg attacks
    function securityCouncilUpgradeApprove(bytes32 _upgradeProposalHash) external onlySecurityCouncil upgradeProposed {
        require(chainStorage.upgrades.proposedUpgradeHash == _upgradeProposalHash, "un");
        chainStorage.upgrades.approvedBySecurityCouncil = true;

        emit SecurityCouncilUpgradeApprove(chainStorage.upgrades.currentProposalId, _upgradeProposalHash);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current governor can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    /// @param _proposalSalt The committed 32 bytes salt for upgrade proposal data
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut, bytes32 _proposalSalt) external onlyGovernor {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        bool approvedBySecurityCouncil = chainStorage.upgrades.approvedBySecurityCouncil;
        ProofUpgradeState upgradeState = chainStorage.upgrades.state;
        if (upgradeState == ProofUpgradeState.Transparent) {
            bool upgradeNoticePeriodPassed = block.timestamp >=
                chainStorage.upgrades.proposedUpgradeTimestamp + UPGRADE_NOTICE_PERIOD;
            require(upgradeNoticePeriodPassed || approvedBySecurityCouncil, "va");
            require(_proposalSalt == bytes32(0), "po"); // The transparent upgrade may be initiated only with zero salt
        } else if (upgradeState == ProofUpgradeState.Shadow) {
            require(approvedBySecurityCouncil, "av");
            require(_proposalSalt != bytes32(0), "op"); // Shadow upgrade should be initialized with "random" salt
        } else {
            revert("ab"); // There is no active upgrade
        }

        require(approvedBySecurityCouncil || !diamondStorage.isFrozen, "f3");
        // Should not be frozen or should have enough security council approvals

        uint256 currentProposalId = chainStorage.upgrades.currentProposalId;
        bytes32 executingProposalHash = upgradeProposalHash(_diamondCut, currentProposalId, _proposalSalt);
        require(chainStorage.upgrades.proposedUpgradeHash == executingProposalHash, "a4"); // Proposal should be created
        _resetProposal();

        if (diamondStorage.isFrozen) {
            diamondStorage.isFrozen = false;
            emit Unfreeze();
        }

        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(currentProposalId, executingProposalHash, _proposalSalt);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Instantly pause the functionality of all freezable facets & their selectors
    function freezeDiamond() external onlyGovernor {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        _resetProposal();
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @notice Unpause the functionality of all freezable facets & their selectors
    function unfreezeDiamond() external onlyGovernor {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        _resetProposal();
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }

    /*//////////////////////////////////////////////////////////////
                            GETTERS & HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Generate the upgrade proposal hash
    /// @param _diamondCut The diamond cut parameters will be executed with the upgrade
    /// @param _proposalId The current proposal ID, to set a unique upgrade hash depending on the upgrades order
    /// @param _salt The arbitrary 32 bytes, primarily used in shadow upgrades to prevent guessing the upgrade proposal content by its hash
    /// @return The upgrade proposal hash
    function upgradeProposalHash(
        Diamond.DiamondCutData calldata _diamondCut,
        uint256 _proposalId,
        bytes32 _salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_diamondCut, _proposalId, _salt));
    }

    /// @dev Set up the proposed upgrade state to the default values
    function _resetProposal() internal {
        delete chainStorage.upgrades.state;
        delete chainStorage.upgrades.proposedUpgradeHash;
        delete chainStorage.upgrades.proposedUpgradeTimestamp;
        delete chainStorage.upgrades.approvedBySecurityCouncil;
    }
}
