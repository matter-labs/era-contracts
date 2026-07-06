// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreContract, CTMContract, EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {UpgradeComposer} from "contracts/upgrades/registry/UpgradeComposer.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {CoreRegistryV99} from "./CoreRegistryV99.sol";
import {EraCTMRegistryV99} from "./EraCTMRegistryV99.sol";

/// @notice Tests the generator's output (checked-in sample from
///         scripts/gen-registry-manifest.example.json) and the on-chain composition the
///         orchestrator performs on top of it. Regenerate with:
///         `ts-node scripts/gen-registry.ts scripts/gen-registry-manifest.example.json
///          test/foundry/l1/unit/concrete/upgrades/registry-gen`
contract GeneratedRegistriesTest is Test {
    CoreRegistryV99 internal coreRegistry;
    EraCTMRegistryV99 internal ctmRegistry;

    uint256 internal constant OLD_VERSION = uint256(98) << 32; // 0.98.0
    uint256 internal constant NEW_VERSION = uint256(99) << 32; // 0.99.0

    function setUp() public {
        coreRegistry = new CoreRegistryV99();
        ctmRegistry = new EraCTMRegistryV99();
    }

    /*//////////////////////////////////////////////////////////////
                        generated getter surface
    //////////////////////////////////////////////////////////////*/

    function test_coreRegistryPinsManifestValues() public view {
        assertEq(coreRegistry.oldProtocolVersion(), OLD_VERSION);
        assertEq(coreRegistry.newProtocolVersion(), NEW_VERSION);
        assertEq(coreRegistry.proxyAddress(EcosystemContract.Bridgehub), address(0xB001));
        assertEq(coreRegistry.implAddress(EcosystemContract.Bridgehub, OLD_VERSION), address(0xB101));
        assertEq(coreRegistry.implAddress(EcosystemContract.Bridgehub, NEW_VERSION), address(0xB201));
        // MessageRoot's implementation is unchanged across the two versions.
        assertEq(
            coreRegistry.implAddress(EcosystemContract.MessageRoot, OLD_VERSION),
            coreRegistry.implAddress(EcosystemContract.MessageRoot, NEW_VERSION)
        );
        assertEq(coreRegistry.proxyAdmin(), address(0xA001));
        assertEq(coreRegistry.ctmRegistry(false), address(0xC001));
        assertEq(coreRegistry.ctmRegistry(true), address(0xC002));
        assertEq(coreRegistry.ecosystemContractList().length, 3);
    }

    function test_ctmRegistryPinsManifestValues() public view {
        assertFalse(ctmRegistry.isZKsyncOS());
        assertEq(ctmRegistry.ctmProxy(), address(0xD001));
        assertEq(ctmRegistry.verifier(NEW_VERSION), address(0xE002));
        assertEq(ctmRegistry.ctmAddress(CTMContract.AdminFacet, OLD_VERSION), address(0xF101));
        assertEq(ctmRegistry.ctmAddress(CTMContract.AdminFacet, NEW_VERSION), address(0xF201));
        assertEq(ctmRegistry.facetList(OLD_VERSION).length, 2);
        assertEq(ctmRegistry.facetList(NEW_VERSION).length, 3);
        assertTrue(ctmRegistry.facetIsFreezable(CTMContract.ExecutorFacet));
        assertFalse(ctmRegistry.facetIsFreezable(CTMContract.AdminFacet));
        assertEq(
            ctmRegistry.l2BytecodeHash(CoreContract.L2Bridgehub, NEW_VERSION),
            bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001))
        );

        bytes4[] memory adminNew = ctmRegistry.facetSelectors(CTMContract.AdminFacet, NEW_VERSION);
        assertEq(adminNew.length, 2);
        assertEq(adminNew[0], bytes4(uint32(2)));
        assertEq(adminNew[1], bytes4(uint32(3)));
    }

    function test_revertWhen_unknownVersionQueried() public {
        vm.expectRevert(CoreRegistryV99.RegistryUnknownKey.selector);
        coreRegistry.implAddress(EcosystemContract.Bridgehub, 12345);

        vm.expectRevert(EraCTMRegistryV99.RegistryUnknownKey.selector);
        ctmRegistry.verifier(12345);

        vm.expectRevert(EraCTMRegistryV99.RegistryUnknownKey.selector);
        ctmRegistry.facetSelectors(CTMContract.MailboxFacet, NEW_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                     composition on generated data
    //////////////////////////////////////////////////////////////*/

    function test_buildFacetSwaps_skipsUnchangedFacet() public view {
        UpgradeComposer.SwapSet memory swapSet = UpgradeComposer.buildFacetSwaps(ICTMRegistry(address(ctmRegistry)));

        // AdminFacet changes address (swap), GettersFacet is unchanged (skipped),
        // ExecutorFacet is new (pure addition).
        assertEq(swapSet.swaps.length, 2);
        assertEq(swapSet.swaps[0].oldFacet, address(0xF101));
        assertEq(swapSet.swaps[0].newFacet, address(0xF201));
        assertFalse(swapSet.swaps[0].isFreezable);
        assertEq(swapSet.swaps[1].oldFacet, address(0));
        assertEq(swapSet.swaps[1].newFacet, address(0xF203));
        assertTrue(swapSet.swaps[1].isFreezable);
    }

    function test_buildUpgradeCutData_diffsSelectors() public view {
        Diamond.DiamondCutData memory cut = UpgradeComposer.buildUpgradeCutData(
            ICTMRegistry(address(ctmRegistry)),
            address(0xF205),
            hex"1234"
        );

        assertEq(cut.initAddress, address(0xF205));
        assertEq(cut.initCalldata, hex"1234");
        // AdminFacet: selector 1 removed, 2 replaced, 3 added; ExecutorFacet: 0x20 added.
        assertEq(cut.facetCuts.length, 4);
        assertEq(uint256(cut.facetCuts[0].action), uint256(Diamond.Action.Remove));
        assertEq(cut.facetCuts[0].selectors[0], bytes4(uint32(1)));
        assertEq(uint256(cut.facetCuts[1].action), uint256(Diamond.Action.Replace));
        assertEq(cut.facetCuts[1].facet, address(0xF201));
        assertEq(cut.facetCuts[1].selectors[0], bytes4(uint32(2)));
        assertEq(uint256(cut.facetCuts[2].action), uint256(Diamond.Action.Add));
        assertEq(cut.facetCuts[2].facet, address(0xF201));
        assertEq(cut.facetCuts[2].selectors[0], bytes4(uint32(3)));
        assertEq(uint256(cut.facetCuts[3].action), uint256(Diamond.Action.Add));
        assertEq(cut.facetCuts[3].facet, address(0xF203));
        assertEq(cut.facetCuts[3].selectors[0], bytes4(uint32(0x20)));
    }

    function test_buildL2UpgradeTx_matchesProtocolRequirements() public view {
        L2CanonicalTransaction memory transaction = UpgradeComposer.buildL2UpgradeTx(
            ICTMRegistry(address(ctmRegistry))
        );

        assertEq(transaction.txType, SYSTEM_UPGRADE_L2_TX_TYPE);
        assertEq(transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)));
        assertEq(transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        // BaseZkSyncUpgrade requires nonce == new minor version.
        assertEq(transaction.nonce, 99);
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(NEW_VERSION));
        assertEq(transaction.nonce, minor);
        assertEq(transaction.factoryDeps.length, 2);
        assertEq(
            transaction.factoryDeps[0],
            uint256(0x0100000000000000000000000000000000000000000000000000000000000001)
        );

        // The tx data is the universal ComplexUpgrader call carrying the registry's deployments.
        assertEq(bytes4(transaction.data), IComplexUpgrader.forceDeployAndUpgradeUniversal.selector);
        bytes memory args = new bytes(transaction.data.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = transaction.data[i + 4];
        }
        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments,
            address delegateTo,
            bytes memory data
        ) = abi.decode(args, (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));
        assertEq(deployments.length, 2);
        assertEq(deployments[0].newAddress, address(0x00010002));
        assertEq(uint256(deployments[0].upgradeType), uint256(IComplexUpgrader.ContractUpgradeType.EraForceDeployment));
        assertEq(deployments[0].deployedBytecodeInfo, hex"aa01");
        assertEq(delegateTo, address(0x00010004));
        assertEq(data, hex"beef");
    }

    function test_buildProposedUpgrade_pinsHashesAndVersion() public view {
        ProposedUpgrade memory proposedUpgrade = UpgradeComposer.buildProposedUpgrade(
            ICTMRegistry(address(ctmRegistry)),
            1234567
        );

        assertEq(proposedUpgrade.newProtocolVersion, NEW_VERSION);
        assertEq(proposedUpgrade.upgradeTimestamp, 1234567);
        assertEq(
            proposedUpgrade.bootloaderHash,
            bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000b00))
        );
        assertEq(
            proposedUpgrade.defaultAccountHash,
            bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000da0))
        );
        assertEq(proposedUpgrade.evmEmulatorHash, bytes32(0));
    }

    function test_buildChainCreationParams_installsFullNewFacetSet() public view {
        ChainCreationParams memory params = UpgradeComposer.buildChainCreationParams(
            ICTMRegistry(address(ctmRegistry))
        );

        assertEq(params.genesisUpgrade, address(0x00010005));
        assertEq(params.genesisIndexRepeatedStorageChanges, 54);
        assertEq(params.forceDeploymentsData, hex"f1f2");
        assertEq(params.diamondCut.initAddress, address(0xF204)); // DiamondInit
        assertEq(params.diamondCut.initCalldata, hex"c1c2c3");
        // All three new facets are pure additions.
        assertEq(params.diamondCut.facetCuts.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(uint256(params.diamondCut.facetCuts[i].action), uint256(Diamond.Action.Add));
        }
        // The chain-creation facet set equals the post-upgrade facet set (no drift by construction):
        // AdminFacet(new) + GettersFacet + ExecutorFacet.
        assertEq(params.diamondCut.facetCuts[0].facet, address(0xF201));
        assertEq(params.diamondCut.facetCuts[1].facet, address(0xF102));
        assertEq(params.diamondCut.facetCuts[2].facet, address(0xF203));
    }

    /*//////////////////////////////////////////////////////////////
                              verifyAll
    //////////////////////////////////////////////////////////////*/

    function test_verifyAll_matchesPinnedCodehash() public {
        // The manifest pins the codehash of the Bridgehub implNew (0xB201). With no code
        // deployed there, verification fails; with the exact audited bytecode, it passes.
        assertFalse(coreRegistry.verifyAll());

        vm.etch(address(0xB201), hex"6001600155");
        assertTrue(coreRegistry.verifyAll());

        // Wrong bytecode fails again.
        vm.etch(address(0xB201), hex"600260025500");
        assertFalse(coreRegistry.verifyAll());
    }
}
