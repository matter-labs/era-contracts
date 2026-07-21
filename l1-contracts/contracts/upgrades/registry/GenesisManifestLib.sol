// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMRelease} from "./CTMRelease.sol";
import {GenesisFacet} from "./ICTMRelease.sol";
import {Facets} from "../../common/StateTransitionTypes.sol";
import {ISelfDescribingFacet} from "../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";

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

    /// @notice Everything the deploy flow feeds into a bootstrap manifest.
    /// @dev A release is version-INDEPENDENT and VM-flag-free: version/verifier are transition
    ///      concerns, and VM identity is single-sourced from the pinned DiamondInit immutable.
    /// @param facets The deployed diamond facet addresses (incl. DiamondInit).
    /// @param bootloaderHash The hash of the bootloader L2 bytecode (zero on ZKsync OS).
    /// @param defaultAccountHash The hash of the default account L2 bytecode (zero on ZKsync OS).
    /// @param evmEmulatorHash The hash of the EVM emulator L2 bytecode (zero on ZKsync OS).
    /// @param genesisUpgrade The L1 genesis upgrade contract run at chain creation.
    /// @param genesisBatchHash The genesis (batch zero) state root.
    /// @param genesisBatchCommitment The genesis batch commitment (must be 1 on ZKsync OS).
    /// @param genesisIndexRepeatedStorageChanges The genesis repeated-storage index.
    /// @param fixedForceDeploymentsData The ecosystem-wide fixed force-deployment descriptor.
    // solhint-disable-next-line gas-struct-packing
    struct GenesisConfig {
        Facets facets;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        bytes32 genesisBatchCommitment;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes fixedForceDeploymentsData;
    }

    function buildGenesisManifest(
        GenesisConfig memory _cfg
    ) internal view returns (CTMRelease.ReleaseManifest memory manifest) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](GENESIS_FACET_COUNT);

        // The canonical facet set of a new chain diamond, with explicit routing and inline pins
        // captured from the just-deployed facets (live calls: this variant runs where the facets
        // exist — in the deployers).
        (address[GENESIS_FACET_COUNT] memory addrs, bool[GENESIS_FACET_COUNT] memory freezable) = genesisFacetSlots(
            _cfg.facets
        );
        for (uint256 i = 0; i < GENESIS_FACET_COUNT; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: addrs[i],
                isFreezable: freezable[i],
                selectors: ISelfDescribingFacet(addrs[i]).selectors(),
                codehash: addrs[i].codehash
            });
        }

        return
            buildGenesisManifestFromRows(
                _cfg,
                genesisFacets,
                _cfg.facets.diamondInit.codehash,
                _cfg.genesisUpgrade.codehash
            );
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
        bytes32 _genesisUpgradeCodehash
    ) internal pure returns (CTMRelease.ReleaseManifest memory manifest) {
        manifest.diamondInit = _cfg.facets.diamondInit;
        manifest.diamondInitCodehash = _diamondInitCodehash;
        manifest.genesisFacets = _genesisFacets;
        manifest.bootloaderHash = _cfg.bootloaderHash;
        manifest.defaultAccountHash = _cfg.defaultAccountHash;
        manifest.evmEmulatorHash = _cfg.evmEmulatorHash;
        manifest.fixedForceDeploymentsData = _cfg.fixedForceDeploymentsData;
        manifest.genesisUpgrade = _cfg.genesisUpgrade;
        manifest.genesisUpgradeCodehash = _genesisUpgradeCodehash;
        manifest.genesisBatchHash = _cfg.genesisBatchHash;
        manifest.genesisBatchCommitment = _cfg.genesisBatchCommitment;
        manifest.genesisIndexRepeatedStorageChanges = _cfg.genesisIndexRepeatedStorageChanges;
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
