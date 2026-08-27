// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Facets} from "../../../common/StateTransitionTypes.sol";
import {GenesisConfig, GenesisFacet, ReleaseManifest} from "../RegistryTypes.sol";

/// @title Genesis (bootstrap) manifest builder.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Builds the release manifest a freshly deployed CTM uses for chain genesis.
/// @dev Shared by the on-chain `GatewayCTMDeployerCTMBase` (zksync-os) and the L1 deploy
///      scripts, so the two genesis paths cannot drift apart.
/// @dev The bootstrap flow deploys the facets and pins them in the same breath, so the explicit
///      selector routing is read from each facet's own `ISelfDescribingFacet.selectors()` and
///      the codehash pins from the live code — at BUILD time. The resulting manifest stores
///      both explicitly; nothing self-describes at consumption time.
library GenesisManifestLib {
    uint256 internal constant GENESIS_FACET_COUNT = 6;

    function buildGenesisManifest(GenesisConfig memory _cfg) internal view returns (ReleaseManifest memory manifest) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](GENESIS_FACET_COUNT);

        // The canonical facet set of a new chain diamond, with inline pins captured from the
        // just-deployed facets (live calls: this variant runs where the facets exist — in the
        // deployers). Routing is not captured: consumers read it from the pinned facets' own
        // self-description.
        (address[GENESIS_FACET_COUNT] memory addrs, bool[GENESIS_FACET_COUNT] memory freezable) = genesisFacetSlots(
            _cfg.facets
        );
        for (uint256 i = 0; i < GENESIS_FACET_COUNT; ++i) {
            genesisFacets[i] = GenesisFacet({facet: addrs[i], isFreezable: freezable[i], codehash: addrs[i].codehash});
        }

        return
            buildGenesisManifestFromRows({
                _cfg: _cfg,
                _genesisFacets: genesisFacets,
                _diamondInitCodehash: _cfg.facets.diamondInit.codehash,
                _verifierCodehash: _cfg.verifier.codehash,
                _genesisUpgradeCodehash: _cfg.genesisUpgrade.codehash
            });
    }

    /// @notice Pure manifest assembly from precomputed facet rows and codehashes. Off-chain
    ///         predictors (`GatewayCTMDeployerHelper`) use this with rows reconstructed from
    ///         build artifacts — the facets do not exist yet at prediction time — and MUST
    ///         reproduce byte-identical rows (same slot order via {genesisFacetSlots}, selectors
    ///         from the facets' own ABI, VM-appropriate codehashes), since
    ///         `keccak256(abi.encode(manifest))` is the release factory's CREATE2 salt.
    function buildGenesisManifestFromRows(
        GenesisConfig memory _cfg,
        GenesisFacet[] memory _genesisFacets,
        bytes32 _diamondInitCodehash,
        bytes32 _verifierCodehash,
        bytes32 _genesisUpgradeCodehash
    ) internal pure returns (ReleaseManifest memory manifest) {
        manifest.diamondInit = _cfg.facets.diamondInit;
        manifest.diamondInitCodehash = _diamondInitCodehash;
        manifest.verifier = _cfg.verifier;
        manifest.verifierCodehash = _verifierCodehash;
        manifest.genesisUpgrade = _cfg.genesisUpgrade;
        manifest.genesisUpgradeCodehash = _genesisUpgradeCodehash;
        manifest.genesisFacets = _genesisFacets;
        // The shared block travels verbatim: config and manifest describe it with the same type.
        manifest.genesis = _cfg.genesis;
    }

    /// @notice The canonical genesis facet slot order + freezability. Shared by the live builder
    ///         and off-chain predictors so the two cannot disagree on row order.
    function genesisFacetSlots(
        Facets memory _facets
    ) internal pure returns (address[GENESIS_FACET_COUNT] memory addrs, bool[GENESIS_FACET_COUNT] memory freezable) {
        addrs[0] = _facets.adminFacet;
        freezable[0] = false;

        addrs[1] = _facets.gettersFacet;
        freezable[1] = false;

        addrs[2] = _facets.mailboxFacet;
        freezable[2] = true;

        addrs[3] = _facets.executorFacet;
        freezable[3] = true;

        addrs[4] = _facets.migratorFacet;
        freezable[4] = false;

        addrs[5] = _facets.committerFacet;
        freezable[5] = true;
    }
}
