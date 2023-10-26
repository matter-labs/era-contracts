// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-interfaces/IVerifier.sol";
import "../Verifier.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../bridgehub/bridgehub-interfaces/IBridgehubForProof.sol";
import "../../common/Messaging.sol";

// import "./libraries/PriorityQueue.sol";

// /// @notice Indicates whether an upgrade is initiated and if yes what type
// /// @param None Upgrade is NOT initiated
// /// @param Transparent Fully transparent upgrade is initiated, upgrade data is publicly known
// /// @param Shadow Shadow upgrade is initiated, upgrade data is hidden
// enum ProofUpgradeState {
//     None,
//     Transparent,
//     Shadow
// }

// /// @dev Logically separated part of the storage structure, which is responsible for everything related to proxy upgrades and diamond cuts
// /// @param proposedUpgradeHash The hash of the current upgrade proposal, zero if there is no active proposal
// /// @param state Indicates whether an upgrade is initiated and if yes what type
// /// @param securityCouncil Address which has the permission to approve instant upgrades (expected to be a Gnosis multisig)
// /// @param approvedBySecurityCouncil Indicates whether the security council has approved the upgrade
// /// @param proposedUpgradeTimestamp The timestamp when the upgrade was proposed, zero if there are no active proposals
// /// @param currentProposalId The serial number of proposed upgrades, increments when proposing a new one
// struct ProofUpgradeStorage {
//     bytes32 proposedUpgradeHash;
//     ProofUpgradeState state;
//     address securityCouncil;
//     bool approvedBySecurityCouncil;
//     uint40 proposedUpgradeTimestamp;
//     uint40 currentProposalId;
// }

/// @dev storing all storage variables for zkSync facets
/// NOTE: It is used in a proxy, so it is possible to add new variables to the end
/// but NOT to modify already existing variables or change their order.
/// NOTE: variables prefixed with '__DEPRECATED_' are deprecated and shouldn't be used.
/// Their presence is maintained for compatibility and to prevent storage collision.
struct StateTransitionStorage {
    /// @notice Address which will exercise governance over the network i.e. change validator set, conduct upgrades
    address governor;
    /// @notice Address that the governor proposed as one that will replace it
    address pendingGovernor;
    /// @notice Address of the factory
    address bridgehub;
    uint256 totalChains;
    mapping(uint256 => address) chainNumberToContract;
    /// @notice chainId => chainContract
    mapping(uint256 => address) stateTransitionChainContract;
    /// @dev Batch hash zero, calculated at initialization
    bytes32 storedBatchZero;
    /// @dev Stored cutData for diamond cut
    bytes32 cutHash;
    /// @dev Diamond Init address for setChainId
    address diamondInit;
    /// @dev Stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 => bytes32) upgradeCutHash;
    /// @dev protocolVersion
    uint256 protocolVersion;
}
