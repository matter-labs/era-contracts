// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";

library GetDiamondCutData {
    /// @notice Read chain creation params from the CTM via `eth_getLogs`.
    /// @param  ctm        Target CTM proxy.
    /// @param  skipLogs   When true, returns `("", "")` without touching
    ///                    `eth_getLogs`. Use from `forge test` contexts where
    ///                    no fork URL is active and the caller already has the
    ///                    diamond-cut data cached (e.g. preloaded from TOML).
    function getDiamondCutAndForceDeployment(
        address ctm,
        bool skipLogs
    ) external view returns (bytes memory diamondCutData, bytes memory forceDeploymentsData) {
        if (skipLogs) {
            return ("", "");
        }
        return _getDiamondCutAndForceDeployment(ctm);
    }

    /// @notice Reconstruct the genesis diamond cut and force-deployments descriptor for a CTM.
    /// @dev From v32 the CTM no longer commits these wholesale (the `NewChainCreationParams` event
    ///      is gone); instead it stores a pointer to its genesis `CTMRegistry` and reads everything
    ///      from there per chain creation. We reproduce the same cut the CTM builds internally: an
    ///      empty-facet cut pointing at `DiamondInit` (the CTM fills in the per-chain init calldata
    ///      itself), and pull the force-deployments blob straight from the registry.
    function _getDiamondCutAndForceDeployment(
        address ctm
    ) internal view returns (bytes memory diamondCutData, bytes memory forceDeploymentsData) {
        ChainTypeManager chainTypeManager = ChainTypeManager(ctm);
        ICTMRelease release = ICTMRelease(chainTypeManager.currentRelease());

        Diamond.DiamondCutData memory cut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: release.diamondInit(),
            initCalldata: ""
        });

        diamondCutData = abi.encode(cut);
        forceDeploymentsData = release.fixedForceDeploymentsData();
    }
}
