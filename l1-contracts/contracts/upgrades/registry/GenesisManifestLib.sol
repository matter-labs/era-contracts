// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "./ContractIdentifiers.sol";
import {CTMRegistry} from "./CTMRegistry.sol";
import {Facets} from "../../common/StateTransitionTypes.sol";

/// @title Genesis (bootstrap) manifest builder.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Builds the `CTMRegistryManifest` a freshly deployed CTM's bootstrap registry is
///         initialized with: only the sections `DiamondInit` reads at chain creation — the
///         new-version facet set (canonical freezability, empty selector lists so facets
///         self-describe) and the base system contract hashes. Everything upgrade-related is
///         empty; `oldProtocolVersion` is zero ("there is no old version").
/// @dev Shared by the on-chain `GatewayCTMDeployerCTMBase` (zksync-os) and the L1 deploy
///      scripts, so the two genesis paths cannot drift apart.
library GenesisManifestLib {
    uint256 internal constant GENESIS_FACET_COUNT = 6;

    /// @param _isZKsyncOS Whether the CTM this registry bootstraps is the ZKsyncOS one.
    /// @param _protocolVersion The packed SemVer protocol version new chains are created at.
    /// @param _facets The deployed diamond facet addresses.
    /// @param _bootloaderHash The hash of the bootloader L2 bytecode (zero on ZKsync OS).
    /// @param _defaultAccountHash The hash of the default account L2 bytecode (zero on ZKsync OS).
    /// @param _evmEmulatorHash The hash of the EVM emulator L2 bytecode (zero on ZKsync OS).
    function buildGenesisManifest(
        bool _isZKsyncOS,
        uint256 _protocolVersion,
        Facets memory _facets,
        bytes32 _bootloaderHash,
        bytes32 _defaultAccountHash,
        bytes32 _evmEmulatorHash
    ) internal pure returns (CTMRegistry.CTMRegistryManifest memory manifest) {
        CTMRegistry.FacetRow[] memory facetRows = new CTMRegistry.FacetRow[](GENESIS_FACET_COUNT);
        CTMRegistry.FreezabilityRow[] memory freezabilityRows = new CTMRegistry.FreezabilityRow[](GENESIS_FACET_COUNT);

        // The canonical facet set of a new chain diamond; empty selector lists mean DiamondInit
        // reads each facet's own `ISelfDescribingFacet.selectors()`.
        (
            CTMContract[GENESIS_FACET_COUNT] memory ids,
            address[GENESIS_FACET_COUNT] memory addrs,
            bool[GENESIS_FACET_COUNT] memory freezable
        ) = _genesisFacets(_facets);
        for (uint256 i = 0; i < GENESIS_FACET_COUNT; ++i) {
            facetRows[i] = CTMRegistry.FacetRow({
                facet: ids[i],
                protocolVersion: _protocolVersion,
                facetAddress: addrs[i],
                selectorList: new bytes4[](0)
            });
            freezabilityRows[i] = CTMRegistry.FreezabilityRow({facet: ids[i], isFreezable: freezable[i]});
        }

        manifest.isZKsyncOS = _isZKsyncOS;
        manifest.newProtocolVersion = _protocolVersion;
        manifest.facetRows = facetRows;
        manifest.freezabilityRows = freezabilityRows;
        manifest.bootloaderHash = _bootloaderHash;
        manifest.defaultAccountHash = _defaultAccountHash;
        manifest.evmEmulatorHash = _evmEmulatorHash;
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
