// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2EcosystemContract} from "./ContractIdentifiers.sol";
import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {UpgradeFacetSwap} from "../../state-transition/libraries/ProposedUpgradeLib.sol";

struct L2Deployment {
    L2EcosystemContract key;
    IComplexUpgrader.UniversalContractUpgradeInfo info;
    bytes32 bytecodeHash;
}

/// @notice Immutable description of how one CTM release becomes another.
interface ICTMTransition {
    function ctmProxy() external view returns (address);

    function oldProtocolVersion() external view returns (uint256);

    function newRelease() external view returns (address);

    function defaultUpgrade() external view returns (address);

    function oldProtocolVersionDeadline() external view returns (uint256);

    function upgradeTimestamp() external view returns (uint256);

    function facetTransitions() external view returns (UpgradeFacetSwap[] memory);

    function l2Deployments() external view returns (L2Deployment[] memory);

    function l2UpgradeDelegate() external view returns (address, bytes memory);

    function factoryDepHashes() external view returns (uint256[] memory);

    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32);

    /// @notice Reverts unless the transition, its target release, and all codehash pins are valid.
    function validate() external view;

    function verifyAll() external view returns (bool);
}
