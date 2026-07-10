// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GenesisRegistry} from "contracts/state-transition/chain-deps/GenesisRegistry.sol";
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {
    RegistryUnknownKey,
    RegistryAlreadyInitialized,
    RegistryLengthMismatch
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for the storage-backed genesis registry.
/// @dev A freshly deployed CTM (L1 deploy scripts or the Gateway CTM deployer) points at this
///      registry so `DiamondInit` installs a new chain's facet set and reads the base system
///      contract hashes from here. These tests exercise the getter surface
///      `RegistryFacetReader.newChainInstallations` and `DiamondInit` read, plus the one-shot
///      init guard.
contract GenesisRegistryTest is Test {
    GenesisRegistry internal registry;

    uint256 internal constant VERSION = 42;
    address internal constant ADMIN = address(0xA11);
    address internal constant GETTERS = address(0x6E1);
    bytes32 internal constant BOOTLOADER_HASH = bytes32(uint256(0xB001));
    bytes32 internal constant DEFAULT_ACCOUNT_HASH = bytes32(uint256(0xDEFA));
    bytes32 internal constant EVM_EMULATOR_HASH = bytes32(uint256(0xE7E7));

    function setUp() public {
        registry = new GenesisRegistry();
    }

    /// @dev Two facets: Admin (not freezable) and Getters (freezable), so both flag branches and
    ///      the address/list lookups are covered.
    function _initTwoFacets() internal {
        CTMContract[] memory facets = new CTMContract[](2);
        facets[0] = CTMContract.AdminFacet;
        facets[1] = CTMContract.GettersFacet;
        address[] memory addresses = new address[](2);
        addresses[0] = ADMIN;
        addresses[1] = GETTERS;
        bool[] memory freezable = new bool[](2);
        freezable[0] = false;
        freezable[1] = true;
        registry.initialize(
            VERSION,
            facets,
            addresses,
            freezable,
            BOOTLOADER_HASH,
            DEFAULT_ACCOUNT_HASH,
            EVM_EMULATOR_HASH
        );
    }

    // ---- Happy path ----

    function test_initializePinsGenesisData() public {
        _initTwoFacets();

        assertEq(registry.newProtocolVersion(), VERSION, "version");

        CTMContract[] memory list = registry.facetList(VERSION);
        assertEq(list.length, 2, "list length");
        assertEq(uint256(list[0]), uint256(CTMContract.AdminFacet), "facet[0]");
        assertEq(uint256(list[1]), uint256(CTMContract.GettersFacet), "facet[1]");

        assertEq(registry.ctmAddress(CTMContract.AdminFacet, VERSION), ADMIN, "admin addr");
        assertEq(registry.ctmAddress(CTMContract.GettersFacet, VERSION), GETTERS, "getters addr");

        assertFalse(registry.facetIsFreezable(CTMContract.AdminFacet), "admin freezable");
        assertTrue(registry.facetIsFreezable(CTMContract.GettersFacet), "getters freezable");

        // Selectors are always empty: DiamondInit self-describes from the facet's own bytecode.
        assertEq(registry.facetSelectors(CTMContract.AdminFacet, VERSION).length, 0, "selectors empty");

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = registry
            .baseSystemContractHashes(VERSION);
        assertEq(bootloaderHash, BOOTLOADER_HASH, "bootloader hash");
        assertEq(defaultAccountHash, DEFAULT_ACCOUNT_HASH, "default account hash");
        assertEq(evmEmulatorHash, EVM_EMULATOR_HASH, "evm emulator hash");
    }

    // ---- Unhappy path ----

    function test_initializeRevertsOnSecondCall() public {
        _initTwoFacets();

        CTMContract[] memory facets = new CTMContract[](1);
        facets[0] = CTMContract.MailboxFacet;
        address[] memory addresses = new address[](1);
        addresses[0] = address(0xBEEF);
        bool[] memory freezable = new bool[](1);
        freezable[0] = true;

        vm.expectRevert(RegistryAlreadyInitialized.selector);
        registry.initialize(VERSION, facets, addresses, freezable, bytes32(0), bytes32(0), bytes32(0));
    }

    function test_initializeRevertsOnAddressLengthMismatch() public {
        CTMContract[] memory facets = new CTMContract[](2);
        facets[0] = CTMContract.AdminFacet;
        facets[1] = CTMContract.GettersFacet;
        address[] memory addresses = new address[](1); // too short
        addresses[0] = ADMIN;
        bool[] memory freezable = new bool[](2);

        vm.expectRevert(RegistryLengthMismatch.selector);
        registry.initialize(VERSION, facets, addresses, freezable, bytes32(0), bytes32(0), bytes32(0));
    }

    function test_initializeRevertsOnFreezableLengthMismatch() public {
        CTMContract[] memory facets = new CTMContract[](2);
        facets[0] = CTMContract.AdminFacet;
        facets[1] = CTMContract.GettersFacet;
        address[] memory addresses = new address[](2);
        bool[] memory freezable = new bool[](1); // too short

        vm.expectRevert(RegistryLengthMismatch.selector);
        registry.initialize(VERSION, facets, addresses, freezable, bytes32(0), bytes32(0), bytes32(0));
    }

    function test_gettersRevertOnUnknownVersion() public {
        _initTwoFacets();

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

    /// @dev Before initialization the pinned version is zero, so every version (including zero) is
    ///      unanswerable — the registry must never masquerade as an empty-but-valid genesis set.
    function test_uninitializedRegistryRejectsAllVersions() public {
        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(0);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(VERSION);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.baseSystemContractHashes(0);
    }

    /// @dev ZKsync OS pins all-zero hashes; the registry must store and serve them as-is (the
    ///      zero-check lives in DiamondInit and is skipped for ZKsync OS chains).
    function test_zeroHashesAreServedForPinnedVersion() public {
        CTMContract[] memory facets = new CTMContract[](0);
        address[] memory addresses = new address[](0);
        bool[] memory freezable = new bool[](0);
        registry.initialize(VERSION, facets, addresses, freezable, bytes32(0), bytes32(0), bytes32(0));

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = registry
            .baseSystemContractHashes(VERSION);
        assertEq(bootloaderHash, bytes32(0), "bootloader hash");
        assertEq(defaultAccountHash, bytes32(0), "default account hash");
        assertEq(evmEmulatorHash, bytes32(0), "evm emulator hash");
        assertEq(registry.facetList(VERSION).length, 0, "facet list empty");
    }
}
