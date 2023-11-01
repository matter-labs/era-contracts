// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../libraries/Diamond.sol";
import "../interfaces/IVerifier.sol";
import "../facets/Base.sol";

interface IOldDiamondCut {
    function proposeDiamondCut(Diamond.FacetCut[] calldata _facetCuts, address _initAddress) external;

    function cancelDiamondCutProposal() external;

    function executeDiamondCutProposal(Diamond.DiamondCutData calldata _diamondCut) external;

    function emergencyFreezeDiamond() external;

    function unfreezeDiamond() external;

    function approveEmergencyDiamondCutAsSecurityCouncilMember(bytes32 _diamondCutHash) external;

    // FIXME: token holders should have the ability to cancel the upgrade

    event DiamondCutProposal(Diamond.FacetCut[] _facetCuts, address _initAddress);

    event DiamondCutProposalCancelation(uint256 currentProposalId, bytes32 indexed proposedDiamondCutHash);

    event DiamondCutProposalExecution(Diamond.DiamondCutData _diamondCut);

    event EmergencyFreeze();

    event Unfreeze(uint256 lastDiamondFreezeTimestamp);

    event EmergencyDiamondCutApproved(
        address indexed _address,
        uint256 currentProposalId,
        uint256 securityCouncilEmergencyApprovals,
        bytes32 indexed proposedDiamondCutHash
    );
}

/// @author Matter Labs
contract DiamondUpgradeInit3 is Base {
    function upgrade(
        uint256 _priorityTxMaxGasLimit,
        address _allowList,
        IVerifier _verifier
    ) external payable returns (bytes32) {
        // Zero out the deprecated storage slots
        delete s.__DEPRECATED_diamondCutStorage;

        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
        s.__DEPRECATED_allowList = _allowList;
        s.verifier = _verifier;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
