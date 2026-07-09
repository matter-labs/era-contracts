// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {IGenesisFacetRegistry} from "./IGenesisFacetRegistry.sol";
import {FacetInstallation} from "../../state-transition/chain-interfaces/IDiamondInit.sol";
import {UpgradeFacetSwap} from "../../state-transition/libraries/ProposedUpgradeLib.sol";

/// @title RegistryFacetReader
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Reads a CTM registry's facet rows into the shapes the diamond-side contracts install:
///         the full facet set for a newly created chain (`DiamondInit`) and the facet-swap plan
///         for an upgrade (`BaseZkSyncUpgrade`).
/// @dev The registry is the single source of facet addresses; the CTM only stores a pointer to it
///      per protocol version (`registryForVersion`). This reader is called at execution time by the
///      contract performing the cut, so nothing is duplicated into CTM state. Selector lists are
///      copied verbatim from the registry — empty (the steady state) means the caller resolves the
///      facet's own `ISelfDescribingFacet.selectors()`; a pinned list is the bootstrap override for
///      facet versions predating that interface. Facet bytecode is immutable, so reads are stable.
library RegistryFacetReader {
    /// @notice The complete facet set a chain created at the registry's new protocol version
    ///         installs at genesis (all pure additions).
    function newChainInstallations(
        IGenesisFacetRegistry _registry
    ) internal view returns (FacetInstallation[] memory installations) {
        uint256 newVersion = _registry.newProtocolVersion();
        CTMContract[] memory facets = _registry.facetList(newVersion);
        uint256 facetsLength = facets.length;
        installations = new FacetInstallation[](facetsLength);
        for (uint256 i = 0; i < facetsLength; ++i) {
            installations[i] = FacetInstallation({
                facet: _registry.ctmAddress(facets[i], newVersion),
                isFreezable: _registry.facetIsFreezable(facets[i]),
                selectors: _registry.facetSelectors(facets[i], newVersion)
            });
        }
    }

    /// @notice The facet-swap plan taking a chain from the registry's old protocol version to its
    ///         new one. The old-version facet rows ARE the plan (one swap per row): a changed facet
    ///         carries its old address, an added facet a zero old address, a removed facet a zero
    ///         new address. Unchanged facets have no old row and thus no swap.
    function facetSwapPlan(ICTMRegistry _registry) internal view returns (UpgradeFacetSwap[] memory plan) {
        uint256 oldVersion = _registry.oldProtocolVersion();
        uint256 newVersion = _registry.newProtocolVersion();
        CTMContract[] memory planFacets = _registry.facetList(oldVersion);
        uint256 planLength = planFacets.length;

        plan = new UpgradeFacetSwap[](planLength);
        for (uint256 i = 0; i < planLength; ++i) {
            CTMContract facet = planFacets[i];
            address oldAddress = _registry.ctmAddress(facet, oldVersion);
            address newAddress = _registry.ctmAddress(facet, newVersion);
            plan[i] = UpgradeFacetSwap({
                oldFacet: oldAddress,
                newFacet: newAddress,
                isFreezable: _registry.facetIsFreezable(facet),
                oldSelectors: oldAddress == address(0) ? new bytes4[](0) : _registry.facetSelectors(facet, oldVersion),
                newSelectors: newAddress == address(0) ? new bytes4[](0) : _registry.facetSelectors(facet, newVersion)
            });
        }
    }
}
