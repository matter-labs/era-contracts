// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RegistryInventoryLengthMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    L2EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";

import {GenesisManifestLib} from "contracts/upgrades/registry/libraries/GenesisManifestLib.sol";
import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {
    GenesisConfig,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Unit tests for `CTMRegistry` in its BOOTSTRAP (genesis) mode: a freshly deployed CTM
///         (L1 deploy scripts or the Gateway CTM deployer) points at one of these so
///         `DiamondInit` installs a new chain's facet set from it. Exercises the getter surface
///         `RegistryFacetReader` / `DiamondInit` read and the manifest-hash commitment.
contract CTMRegistryBootstrapTest is Test {
    uint256 internal constant VERSION = 42;
    address internal constant GENESIS_UPGRADE = address(0xABCD);
    address internal constant VERIFIER = address(0xABCE);

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
        // The bootstrap manifest builder reads each facet's explicit routing from its own
        // self-description at BUILD time; mock it on the synthetic facet addresses. Every pinned
        // target must also carry real code — the registry's codehash pin rejects a codeless
        // target — so etch a distinct nonempty stand-in wherever a pin is captured.
        address[6] memory facetAddrs = [
            facets.adminFacet,
            facets.gettersFacet,
            facets.mailboxFacet,
            facets.executorFacet,
            facets.migratorFacet,
            facets.committerFacet
        ];
        for (uint256 i = 0; i < facetAddrs.length; ++i) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(uint32(0x100 + i));
            vm.mockCall(
                facetAddrs[i],
                abi.encodeWithSelector(ISelfDescribingFacet.selectors.selector),
                abi.encode(selectors)
            );
            vm.etch(facetAddrs[i], bytes.concat(hex"6000", bytes1(uint8(i))));
        }
        // `diamondInit` and `genesisUpgrade` are pinned by the manifest too (see `_genesisManifest`).
        vm.etch(facets.diamondInit, hex"600001");
        vm.etch(GENESIS_UPGRADE, hex"600002");
        vm.etch(VERIFIER, hex"600003");
    }

    function _genesisManifest() internal view returns (ReleaseManifest memory) {
        return
            GenesisManifestLib.buildGenesisManifest(
                GenesisConfig({
                    facets: facets,
                    verifier: VERIFIER,
                    genesisUpgrade: GENESIS_UPGRADE,
                    genesis: ReleaseGenesisData({
                        fixedForceDeploymentsData: bytes(""),
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisBatchCommitment: bytes32(uint256(1)),
                        genesisIndexRepeatedStorageChanges: 1
                    }),
                    // Length-checked inventory; content is irrelevant to these fixtures.
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
                })
            );
    }

    // ---- Happy path ----

    function test_constructorPinsGenesisManifest() public {
        ReleaseManifest memory manifest = _genesisManifest();
        CTMRelease release = new CTMRelease(manifest);

        assertEq(release.manifestHash(), keccak256(abi.encode(manifest)), "manifest hash");

        GenesisFacet[] memory list = release.genesisFacets();
        assertEq(list.length, 6, "list length");
        assertEq(list[0].facet.addr, facets.adminFacet, "admin addr");
        assertEq(list[1].facet.addr, facets.gettersFacet, "getters addr");
        assertEq(list[5].facet.addr, facets.committerFacet, "committer addr");

        // Canonical freezability: Mailbox/Executor/Committer freezable, the rest not.
        assertFalse(list[0].isFreezable, "admin freezable");
        assertTrue(list[2].isFreezable, "mailbox freezable");
        assertTrue(list[5].isFreezable, "committer freezable");

        // Routing is not stored in the manifest: it is read from the pinned facet's own
        // self-description on demand.
        bytes4[] memory adminSelectors = ISelfDescribingFacet(list[0].facet.addr).selectors();
        assertEq(adminSelectors.length, 1, "self-described selectors");
        assertEq(adminSelectors[0], bytes4(uint32(0x100)), "admin selector");

        // Inline pins captured from live code at build time (the etched synthetic facets carry
        // real, nonempty code) verify against the same live state.
        release.validate();
        assertTrue(release.verifyAll(), "verifyAll");
    }

    // ---- Unhappy path ----

    function test_constructorRevertsOnZeroGenesisUpgrade() public {
        // Version validation moved to the transition; a release still rejects a zero genesisUpgrade.
        // Build the manifest BEFORE arming expectRevert: the builder itself makes (mocked)
        // external self-description calls that would otherwise consume the expectation.
        ReleaseManifest memory manifest = _genesisManifest();
        manifest.genesisUpgrade.addr = address(0);

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
        CTMRelease release = new CTMRelease(manifest);

        bytes[] memory rows = release.l2BytecodeInfos();
        assertEq(rows.length, L2_ECOSYSTEM_CONTRACT_COUNT, "table length");
        assertEq(rows[uint256(L2EcosystemContract.L2Bridgehub)], hex"beef", "pinned row");
        assertEq(rows[uint256(L2EcosystemContract.L2AssetRouter)].length, 0, "inert slot");
    }
}
