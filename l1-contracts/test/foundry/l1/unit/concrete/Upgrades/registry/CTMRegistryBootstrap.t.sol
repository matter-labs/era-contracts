// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMRegistry} from "contracts/upgrades/registry/CTMRegistry.sol";
import {GenesisManifestLib} from "contracts/upgrades/registry/GenesisManifestLib.sol";
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {RegistryUnknownKey, RegistryAlreadyInitialized} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for `CTMRegistry` in its BOOTSTRAP (genesis) mode: a freshly deployed CTM
///         (L1 deploy scripts or the Gateway CTM deployer) points at one of these so
///         `DiamondInit` installs a new chain's facet set and reads the base system contract
///         hashes from it. Exercises the getter surface `RegistryFacetReader` / `DiamondInit`
///         read, the one-shot init guard, and the manifest-hash commitment.
contract CTMRegistryBootstrapTest is Test {
    CTMRegistry internal registry;

    uint256 internal constant VERSION = 42;
    bytes32 internal constant BOOTLOADER_HASH = bytes32(uint256(0xB001));
    bytes32 internal constant DEFAULT_ACCOUNT_HASH = bytes32(uint256(0xDEFA));
    bytes32 internal constant EVM_EMULATOR_HASH = bytes32(uint256(0xE7E7));

    Facets internal facets =
        Facets({
            adminFacet: address(0xA11),
            mailboxFacet: address(0x111A),
            executorFacet: address(0xE8E),
            gettersFacet: address(0x6E1),
            migratorFacet: address(0x111),
            committerFacet: address(0xC0111),
            diamondInit: address(0xD1)
        });

    function setUp() public {
        registry = new CTMRegistry();
    }

    function _genesisManifest() internal view returns (CTMRegistry.CTMRegistryManifest memory) {
        return
            GenesisManifestLib.buildGenesisManifest(
                false,
                VERSION,
                facets,
                BOOTLOADER_HASH,
                DEFAULT_ACCOUNT_HASH,
                EVM_EMULATOR_HASH
            );
    }

    // ---- Happy path ----

    function test_initializePinsGenesisManifest() public {
        CTMRegistry.CTMRegistryManifest memory manifest = _genesisManifest();
        registry.initialize(manifest);

        assertTrue(registry.initialized(), "initialized");
        assertEq(registry.manifestHash(), keccak256(abi.encode(manifest)), "manifest hash");
        assertEq(registry.newProtocolVersion(), VERSION, "version");
        assertEq(registry.oldProtocolVersion(), 0, "no old version at genesis");
        assertFalse(registry.isZKsyncOS(), "vm flavour");

        CTMContract[] memory list = registry.facetList(VERSION);
        assertEq(list.length, 6, "list length");
        assertEq(uint256(list[0]), uint256(CTMContract.AdminFacet), "facet[0]");
        assertEq(uint256(list[5]), uint256(CTMContract.CommitterFacet), "facet[5]");

        assertEq(registry.ctmAddress(CTMContract.AdminFacet, VERSION), facets.adminFacet, "admin addr");
        assertEq(registry.ctmAddress(CTMContract.GettersFacet, VERSION), facets.gettersFacet, "getters addr");

        // Canonical freezability: Mailbox/Executor/Committer freezable, the rest not.
        assertFalse(registry.facetIsFreezable(CTMContract.AdminFacet), "admin freezable");
        assertTrue(registry.facetIsFreezable(CTMContract.MailboxFacet), "mailbox freezable");
        assertTrue(registry.facetIsFreezable(CTMContract.CommitterFacet), "committer freezable");

        // Selectors are always empty at genesis: DiamondInit self-describes from the facet's own
        // bytecode.
        assertEq(registry.facetSelectors(CTMContract.AdminFacet, VERSION).length, 0, "selectors empty");

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = registry
            .baseSystemContractHashes(VERSION);
        assertEq(bootloaderHash, BOOTLOADER_HASH, "bootloader hash");
        assertEq(defaultAccountHash, DEFAULT_ACCOUNT_HASH, "default account hash");
        assertEq(evmEmulatorHash, EVM_EMULATOR_HASH, "evm emulator hash");

        // No codehash pins in a bootstrap manifest: trivially verified.
        assertTrue(registry.verifyAll(), "verifyAll");
    }

    // ---- Unhappy path ----

    function test_initializeRevertsOnSecondCall() public {
        registry.initialize(_genesisManifest());

        vm.expectRevert(RegistryAlreadyInitialized.selector);
        registry.initialize(_genesisManifest());
    }

    function test_initializeRevertsOnZeroNewVersion() public {
        CTMRegistry.CTMRegistryManifest memory manifest = _genesisManifest();
        manifest.newProtocolVersion = 0;

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.initialize(manifest);
    }

    function test_gettersRevertOnUnknownVersion() public {
        registry.initialize(_genesisManifest());

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(VERSION + 1);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.ctmAddress(CTMContract.AdminFacet, VERSION + 1);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetSelectors(CTMContract.AdminFacet, VERSION + 1);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.baseSystemContractHashes(VERSION + 1);
    }

    // ---- Edge cases ----

    /// @dev Before initialization both pinned versions are zero, so every version (including
    ///      zero) is unanswerable — the registry must never masquerade as an empty-but-valid
    ///      genesis set. The same holds for version 0 AFTER genesis init, where
    ///      `oldProtocolVersion == 0` means "there is no old version".
    function test_versionZeroNeverAnswerable() public {
        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(0);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(VERSION);

        registry.initialize(_genesisManifest());

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(0);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.baseSystemContractHashes(0);
    }

    /// @dev ZKsync OS pins all-zero hashes; the registry must store and serve them as-is (the
    ///      zero-check lives in DiamondInit and is skipped for ZKsync OS chains).
    function test_zeroHashesAreServedForPinnedVersion() public {
        registry.initialize(GenesisManifestLib.buildGenesisManifest(true, VERSION, facets, 0, 0, 0));

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = registry
            .baseSystemContractHashes(VERSION);
        assertEq(bootloaderHash, bytes32(0), "bootloader hash");
        assertEq(defaultAccountHash, bytes32(0), "default account hash");
        assertEq(evmEmulatorHash, bytes32(0), "evm emulator hash");
        assertTrue(registry.isZKsyncOS(), "vm flavour");
        assertEq(registry.facetList(VERSION).length, 6, "facet list");
    }
}
