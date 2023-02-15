// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libraries/Diamond.sol";

interface IDiamondCut {
    function proposeTransparentUpgrade(Diamond.DiamondCutData calldata _diamondCut, uint40 _proposalId) external;

    function proposeShadowUpgrade(bytes32 _proposalHash, uint40 _proposalId) external;

    function cancelUpgradeProposal(bytes32 _proposedUpgradeHash) external;

    function securityCouncilUpgradeApprove(bytes32 _upgradeProposalHash) external;

    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut, bytes32 _proposalSalt) external;

    function freezeDiamond() external;

    function unfreezeDiamond() external;

    function upgradeProposalHash(
        Diamond.DiamondCutData calldata _diamondCut,
        uint256 _proposalId,
        bytes32 _salt
    ) external pure returns (bytes32);

    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );

    event ProposeShadowUpgrade(uint256 indexed proposalId, bytes32 indexed proposalHash);

    event CancelUpgradeProposal(uint256 indexed proposalId, bytes32 indexed proposalHash);

    event SecurityCouncilUpgradeApprove(uint256 indexed proposalId, bytes32 indexed proposalHash);

    event ExecuteUpgrade(uint256 indexed proposalId, bytes32 indexed proposalHash, bytes32 proposalSalt);

    event Freeze();

    event Unfreeze();
}
