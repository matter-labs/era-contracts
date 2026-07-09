// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GatewayGenesisRegistry} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayGenesisRegistry.sol";
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {
    RegistryUnknownKey,
    RegistryAlreadyInitialized,
    RegistryLengthMismatch
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for the storage-backed Gateway genesis facet registry.
/// @dev The Gateway CTM points at this registry so `DiamondInit` installs a new chain's facet set
///      from here, mirroring the L1 registry-driven genesis path. These tests exercise the getter
///      surface `RegistryFacetReader.newChainInstallations` reads, plus the one-shot init guard.
contract GatewayGenesisRegistryTest is Test {
    GatewayGenesisRegistry internal registry;

    uint256 internal constant VERSION = 42;
    address internal constant ADMIN = address(0xA11);
    address internal constant GETTERS = address(0x6E1);

    function setUp() public {
        registry = new GatewayGenesisRegistry();
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
        registry.initialize(VERSION, facets, addresses, freezable);
    }

    // ---- Happy path ----

    function test_initializePinsFacetSet() public {
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
        registry.initialize(VERSION, facets, addresses, freezable);
    }

    function test_initializeRevertsOnAddressLengthMismatch() public {
        CTMContract[] memory facets = new CTMContract[](2);
        facets[0] = CTMContract.AdminFacet;
        facets[1] = CTMContract.GettersFacet;
        address[] memory addresses = new address[](1); // too short
        addresses[0] = ADMIN;
        bool[] memory freezable = new bool[](2);

        vm.expectRevert(RegistryLengthMismatch.selector);
        registry.initialize(VERSION, facets, addresses, freezable);
    }

    function test_initializeRevertsOnFreezableLengthMismatch() public {
        CTMContract[] memory facets = new CTMContract[](2);
        facets[0] = CTMContract.AdminFacet;
        facets[1] = CTMContract.GettersFacet;
        address[] memory addresses = new address[](2);
        bool[] memory freezable = new bool[](1); // too short

        vm.expectRevert(RegistryLengthMismatch.selector);
        registry.initialize(VERSION, facets, addresses, freezable);
    }

    function test_gettersRevertOnUnknownVersion() public {
        _initTwoFacets();

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(VERSION + 1);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.ctmAddress(CTMContract.AdminFacet, VERSION + 1);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetSelectors(CTMContract.AdminFacet, VERSION + 1);
    }

    // ---- Edge case ----

    /// @dev Before initialization the pinned version is zero, so every version (including zero) is
    ///      unanswerable — the registry must never masquerade as an empty-but-valid genesis set.
    function test_uninitializedRegistryRejectsAllVersions() public {
        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(0);

        vm.expectRevert(RegistryUnknownKey.selector);
        registry.facetList(VERSION);
    }
}
