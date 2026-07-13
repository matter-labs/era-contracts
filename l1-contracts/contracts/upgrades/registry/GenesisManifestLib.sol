// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "./ContractIdentifiers.sol";
import {CTMRegistry} from "./CTMRegistry.sol";
import {Facets} from "../../common/StateTransitionTypes.sol";

/// @title Genesis (bootstrap) manifest builder.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Builds the `CTMRegistryManifest` a freshly deployed CTM's bootstrap registry is
///         initialized with. The registry is the CTM's single source of genesis data, so the
///         manifest pins everything chain creation reads: the new-version facet set (canonical
///         freezability, empty selector lists so facets self-describe), the DiamondInit address,
///         the base system contract hashes, the genesis params (`genesisParams`) and the fixed
///         force-deployments data. Everything upgrade-related is empty; `oldProtocolVersion` is
///         zero ("there is no old version").
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
    ) internal pure returns (CTMRegistry.CTMRegistryManifest memory manifest) {
        CTMRegistry.FacetRow[] memory facetRows = new CTMRegistry.FacetRow[](GENESIS_FACET_COUNT);
        CTMRegistry.FreezabilityRow[] memory freezabilityRows = new CTMRegistry.FreezabilityRow[](GENESIS_FACET_COUNT);

        // The canonical facet set of a new chain diamond; empty selector lists mean DiamondInit
        // reads each facet's own `ISelfDescribingFacet.selectors()`.
        (
            CTMContract[GENESIS_FACET_COUNT] memory ids,
            address[GENESIS_FACET_COUNT] memory addrs,
            bool[GENESIS_FACET_COUNT] memory freezable
        ) = _genesisFacets(_cfg.facets);
        for (uint256 i = 0; i < GENESIS_FACET_COUNT; ++i) {
            facetRows[i] = CTMRegistry.FacetRow({
                facet: ids[i],
                protocolVersion: _cfg.protocolVersion,
                facetAddress: addrs[i],
                selectorList: new bytes4[](0)
            });
            freezabilityRows[i] = CTMRegistry.FreezabilityRow({facet: ids[i], isFreezable: freezable[i]});
        }

        // The CTM reads the DiamondInit address from the registry to build every genesis cut.
        CTMRegistry.AddressRow[] memory addressRows = new CTMRegistry.AddressRow[](1);
        addressRows[0] = CTMRegistry.AddressRow({
            key: CTMContract.DiamondInit,
            protocolVersion: _cfg.protocolVersion,
            value: _cfg.facets.diamondInit
        });

        manifest.isZKsyncOS = _cfg.isZKsyncOS;
        manifest.newProtocolVersion = _cfg.protocolVersion;
        manifest.ctmAddressRows = addressRows;
        manifest.facetRows = facetRows;
        manifest.freezabilityRows = freezabilityRows;
        manifest.bootloaderHash = _cfg.bootloaderHash;
        manifest.defaultAccountHash = _cfg.defaultAccountHash;
        manifest.evmEmulatorHash = _cfg.evmEmulatorHash;
        manifest.fixedForceDeploymentsData = _cfg.fixedForceDeploymentsData;
        manifest.genesisUpgrade = _cfg.genesisUpgrade;
        manifest.genesisBatchHash = _cfg.genesisBatchHash;
        manifest.genesisBatchCommitment = _cfg.genesisBatchCommitment;
        manifest.genesisIndexRepeatedStorageChanges = _cfg.genesisIndexRepeatedStorageChanges;
        // All other sections stay empty/zero: a bootstrap registry serves genesis only; the
        // first protocol upgrade repoints the CTM at that upgrade's own registry.
    }

    function _genesisFacets(
        Facets memory _facets
    )
        private
        pure
        returns (
            CTMContract[GENESIS_FACET_COUNT] memory ids,
            address[GENESIS_FACET_COUNT] memory addrs,
            bool[GENESIS_FACET_COUNT] memory freezable
        )
    {
        ids[0] = CTMContract.AdminFacet;
        addrs[0] = _facets.adminFacet;
        freezable[0] = false;

        ids[1] = CTMContract.GettersFacet;
        addrs[1] = _facets.gettersFacet;
        freezable[1] = false;

        ids[2] = CTMContract.MailboxFacet;
        addrs[2] = _facets.mailboxFacet;
        freezable[2] = true;

        ids[3] = CTMContract.ExecutorFacet;
        addrs[3] = _facets.executorFacet;
        freezable[3] = true;

        ids[4] = CTMContract.MigratorFacet;
        addrs[4] = _facets.migratorFacet;
        freezable[4] = false;

        ids[5] = CTMContract.CommitterFacet;
        addrs[5] = _facets.committerFacet;
        freezable[5] = true;
    }
}
