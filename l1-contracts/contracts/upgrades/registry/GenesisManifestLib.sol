// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMRelease} from "./CTMRelease.sol";
import {GenesisFacet} from "./ICTMRelease.sol";
import {Facets} from "../../common/StateTransitionTypes.sol";

/// @title Genesis (bootstrap) manifest builder.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Builds the release manifest a freshly deployed CTM uses for chain genesis.
/// @dev Shared by the on-chain `GatewayCTMDeployerCTMBase` (zksync-os) and the L1 deploy
///      scripts, so the two genesis paths cannot drift apart.
library GenesisManifestLib {
    uint256 internal constant GENESIS_FACET_COUNT = 6;

    /// @notice Everything the deploy flow feeds into a bootstrap manifest.
    /// @param isZKsyncOS Whether the CTM this registry bootstraps is the ZKsyncOS one.
    /// @param protocolVersion The packed SemVer protocol version new chains are created at.
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
        bool isZKsyncOS;
        uint256 protocolVersion;
        address verifier;
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
    ) internal pure returns (CTMRelease.ReleaseManifest memory manifest) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](GENESIS_FACET_COUNT);

        // The canonical facet set of a new chain diamond; empty selector lists mean DiamondInit
        // reads each facet's own `ISelfDescribingFacet.selectors()`.
        (
            address[GENESIS_FACET_COUNT] memory addrs,
            bool[GENESIS_FACET_COUNT] memory freezable
        ) = _genesisFacets(_cfg.facets);
        for (uint256 i = 0; i < GENESIS_FACET_COUNT; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: addrs[i],
                isFreezable: freezable[i],
                selectors: new bytes4[](0)
            });
        }

        manifest.isZKsyncOS = _cfg.isZKsyncOS;
        manifest.protocolVersion = _cfg.protocolVersion;
        manifest.verifier = _cfg.verifier;
        manifest.diamondInit = _cfg.facets.diamondInit;
        manifest.genesisFacets = genesisFacets;
        manifest.bootloaderHash = _cfg.bootloaderHash;
        manifest.defaultAccountHash = _cfg.defaultAccountHash;
        manifest.evmEmulatorHash = _cfg.evmEmulatorHash;
        manifest.fixedForceDeploymentsData = _cfg.fixedForceDeploymentsData;
        manifest.genesisUpgrade = _cfg.genesisUpgrade;
        manifest.genesisBatchHash = _cfg.genesisBatchHash;
        manifest.genesisBatchCommitment = _cfg.genesisBatchCommitment;
        manifest.genesisIndexRepeatedStorageChanges = _cfg.genesisIndexRepeatedStorageChanges;
    }

    function _genesisFacets(
        Facets memory _facets
    )
        private
        pure
        returns (
            address[GENESIS_FACET_COUNT] memory addrs,
            bool[GENESIS_FACET_COUNT] memory freezable
        )
    {
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
