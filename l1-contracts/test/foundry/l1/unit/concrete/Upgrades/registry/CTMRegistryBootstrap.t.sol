// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RegistryInventoryLengthMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    L2EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";

import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Unit tests for `CTMRelease` in its BOOTSTRAP (genesis) role: a freshly deployed CTM
///         (L1 deploy scripts or the Gateway CTM deployer) points at one so `DiamondInit`
///         installs a new chain's facet set from it. Exercises the getter surface
///         `ReleaseFacetReader` / `DiamondInit` read and the manifest-hash commitment.
contract CTMRegistryBootstrapTest is Test {
    uint256 internal constant VERSION = 42;
    address internal constant GENESIS_UPGRADE = address(0xABCD);
    address internal constant VERIFIER = address(0xABCE);
    address internal constant DIAMOND_INIT = address(0xD1);
    uint256 internal constant FACET_COUNT = 3;

    /// @dev Synthetic facets, each with a one-selector self-description and a distinct code.
    address[FACET_COUNT] internal facetAddrs = [address(0xA11), address(0x6E1), address(0x111A)];
    bool[FACET_COUNT] internal facetFreezable = [false, false, true];

    function setUp() public {
        // Consumers read each facet's routing from its own self-description; mock it on the
        // synthetic facet addresses. Every pinned target must also carry real code — the
        // release's `validate()` rejects a codeless member — so etch a distinct nonempty
        // stand-in wherever a pin is captured.
        for (uint256 i = 0; i < FACET_COUNT; ++i) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(uint32(0x100 + i));
            vm.mockCall(
                facetAddrs[i],
                abi.encodeWithSelector(ISelfDescribingFacet.selectors.selector),
                abi.encode(selectors)
            );
            vm.etch(facetAddrs[i], bytes.concat(hex"6000", bytes1(uint8(i))));
        }
        vm.etch(DIAMOND_INIT, hex"600001");
        vm.etch(GENESIS_UPGRADE, hex"600002");
        vm.etch(VERIFIER, hex"600003");
    }

    /// @dev The manifest exactly as a producer assembles it: one row per deployed facet with its
    ///      live pin and freezability, live pins for the fixed members, an empty L2 inventory.
    function _genesisManifest() internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory rows = new GenesisFacet[](FACET_COUNT);
        for (uint256 i = 0; i < FACET_COUNT; ++i) {
            rows[i] = GenesisFacet({facet: (facetAddrs[i]), isFreezable: facetFreezable[i]});
        }
        return
            ReleaseManifest({
                diamondInit: (DIAMOND_INIT),
                verifier: (VERIFIER),
                genesisUpgrade: (GENESIS_UPGRADE),
                genesisFacets: rows,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: bytes(""),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 1
                }),
                // Length-checked inventory; content is irrelevant to these fixtures.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }

    // ---- Happy path ----

    function test_constructorPinsGenesisManifest() public {
        ReleaseManifest memory manifest = _genesisManifest();
        CTMRelease release = new CTMRelease(manifest);

        assertEq(release.manifestHash(), keccak256(abi.encode(manifest)), "manifest hash");

        // The rows are served exactly as pinned: address, codehash and freezability per facet.
        GenesisFacet[] memory list = release.genesisFacets();
        assertEq(list.length, FACET_COUNT, "list length");
        for (uint256 i = 0; i < FACET_COUNT; ++i) {
            assertEq(list[i].facet, facetAddrs[i], "facet addr");
            assertEq(list[i].facet.codehash, facetAddrs[i].codehash, "facet codehash");
            assertEq(list[i].isFreezable, facetFreezable[i], "facet freezability");
        }

        // Routing is not stored in the manifest: it is read from the facet's own
        // self-description on demand.
        bytes4[] memory firstSelectors = ISelfDescribingFacet(list[0].facet).selectors();
        assertEq(firstSelectors.length, 1, "self-described selectors");
        assertEq(firstSelectors[0], bytes4(uint32(0x100)), "first selector");

        // Every named member is deployed code (the etched synthetic facets carry real, nonempty
        // code), so the enforcement surface passes.
        release.validate();
    }

    // ---- Unhappy path ----

    function test_constructorRevertsOnZeroGenesisUpgrade() public {
        // Version validation moved to the transition; a release still rejects a zero genesisUpgrade.
        ReleaseManifest memory manifest = _genesisManifest();
        manifest.genesisUpgrade = address(0);

        vm.expectRevert();
        new CTMRelease(manifest);
    }

    // ---- L2 bytecode table ----

    // The table is an enum-indexed inventory: a wrong-length table cannot construct, so every
    // slot is an explicit statement.
    function test_revertWhen_l2BytecodeTableHasWrongLength() public {
        ReleaseManifest memory manifest = _genesisManifest();
        manifest.l2BytecodeInfos = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryInventoryLengthMismatch.selector,
                L2_ECOSYSTEM_CONTRACT_COUNT,
                L2_ECOSYSTEM_CONTRACT_COUNT - 1
            )
        );
        new CTMRelease(manifest);
    }

    function test_l2BytecodeTableIsServed() public {
        ReleaseManifest memory manifest = _genesisManifest();
        manifest.l2BytecodeInfos[uint256(L2EcosystemContract.L2Bridgehub)] = hex"beef";
        manifest.l2SystemProxyBytecodeInfo = hex"5e11";
        CTMRelease release = new CTMRelease(manifest);

        bytes[] memory rows = release.l2BytecodeInfos();
        assertEq(rows.length, L2_ECOSYSTEM_CONTRACT_COUNT, "table length");
        assertEq(rows[uint256(L2EcosystemContract.L2Bridgehub)], hex"beef", "pinned row");
        assertEq(rows[uint256(L2EcosystemContract.L2AssetRouter)].length, 0, "inert slot");
        assertEq(release.l2SystemProxyBytecodeInfo(), hex"5e11", "the one shared shell");
    }
}
