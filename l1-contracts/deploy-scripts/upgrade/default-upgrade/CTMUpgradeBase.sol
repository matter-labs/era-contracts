// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2EcosystemContract} from "../../ecosystem/CoreContract.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";

/// @notice The version-specific inputs a CTM upgrade prepare contributes to the L2 side of its
///         edge. The payload itself is NOT composed here: the registry objects compose the
///         committed cut and the L2 transaction on-chain from what they pin (see
///         {docs/registry-driven-upgrades.md}), so a prepare only supplies the extras a release
///         table cannot express and the bytecodes those extras need published.
abstract contract CTMUpgradeBase is DeployCTMScript {
    /// @notice Override to add version-specific force deployments in universal format. They ride
    ///         the transition's authored L2 plan, appended after the release table's derived set.
    function getAdditionalUniversalForceDeployments()
        internal
        virtual
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        return new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
    }

    /// @notice Override to add version-specific bytecodes to the factory deps publication set.
    function getAdditionalFactoryDependencyContracts()
        internal
        virtual
        returns (L2EcosystemContract[] memory additionalDependencyContracts)
    {
        return new L2EcosystemContract[](0);
    }

    /// @notice Returns the FixedForceDeploymentsData for bytecodeInfo reuse.
    /// @dev Override in DefaultCTMUpgrade to return cached data (avoids double-loading).
    function getFixedForceDeploymentsData() internal virtual returns (FixedForceDeploymentsData memory);
}
