// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreContract, CTMContract, EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {RegistryFacetReader} from "contracts/upgrades/registry/RegistryFacetReader.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {FacetInstallation} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ProposedUpgrade, UpgradeFacetSwap} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {RegistryUnknownKey} from "contracts/common/L1ContractErrors.sol";

import {CoreRegistryV99} from "./CoreRegistryV99.sol";
import {ZKsyncOSCTMRegistryV99} from "./ZKsyncOSCTMRegistryV99.sol";

/// @notice Tests the generator's output (checked-in sample from
///         scripts/gen-registry-manifest.example.json) and the on-chain composition the
///         orchestrator performs on top of it. Regenerate with:
///         `ts-node scripts/gen-registry.ts scripts/gen-registry-manifest.example.json
///          test/foundry/l1/unit/concrete/upgrades/registry-gen`
contract GeneratedRegistriesTest is Test {
    CoreRegistryV99 internal coreRegistry;
    ZKsyncOSCTMRegistryV99 internal ctmRegistry;

    uint256 internal constant OLD_VERSION = uint256(98) << 32; // 0.98.0
    uint256 internal constant NEW_VERSION = uint256(99) << 32; // 0.99.0

    function setUp() public {
        coreRegistry = new CoreRegistryV99();
        ctmRegistry = new ZKsyncOSCTMRegistryV99();
    }

    /*//////////////////////////////////////////////////////////////
                        generated getter surface
    //////////////////////////////////////////////////////////////*/

    function test_coreRegistryPinsManifestValues() public view {
        assertEq(coreRegistry.oldProtocolVersion(), OLD_VERSION);
        assertEq(coreRegistry.newProtocolVersion(), NEW_VERSION);
        assertEq(coreRegistry.proxyAddress(EcosystemContract.Bridgehub), address(0xB001));
        assertEq(coreRegistry.implAddress(EcosystemContract.Bridgehub), address(0xB201));
        assertEq(coreRegistry.implAddress(EcosystemContract.L1AssetRouter), address(0xB202));
        // MessageRoot participates (its proxy is pinned) but this upgrade pins no new
        // implementation for it: zero means "nothing to upgrade".
        assertEq(coreRegistry.implAddress(EcosystemContract.MessageRoot), address(0));
        assertEq(coreRegistry.proxyAdmin(), address(0xA001));
        assertEq(coreRegistry.ctmRegistry(false), address(0xC001));
        assertEq(coreRegistry.ctmRegistry(true), address(0xC002));
        assertEq(coreRegistry.ecosystemContractList().length, 3);
    }

    function test_ctmRegistryPinsManifestValues() public view {
        assertTrue(ctmRegistry.isZKsyncOS());
        assertEq(ctmRegistry.ctmProxy(), address(0xD001));
        assertEq(ctmRegistry.verifier(NEW_VERSION), address(0xE002));
        // Facet addresses resolve from the facet rows: the old side pins only the facets the
        // upgrade touches, the new side the complete post-upgrade set.
        assertEq(ctmRegistry.ctmAddress(CTMContract.AdminFacet, OLD_VERSION), address(0xF101)); // changed
        assertEq(ctmRegistry.ctmAddress(CTMContract.AdminFacet, NEW_VERSION), address(0xF201));
        assertEq(ctmRegistry.ctmAddress(CTMContract.GettersFacet, OLD_VERSION), address(0)); // unchanged: no old row
        assertEq(ctmRegistry.ctmAddress(CTMContract.GettersFacet, NEW_VERSION), address(0xF102));
        assertEq(ctmRegistry.ctmAddress(CTMContract.ExecutorFacet, OLD_VERSION), address(0)); // added
        assertEq(ctmRegistry.ctmAddress(CTMContract.MailboxFacet, NEW_VERSION), address(0)); // removed
        assertEq(ctmRegistry.ctmAddress(CTMContract.MailboxFacet, OLD_VERSION), address(0xF103));
        // Old facet list = the upgrade plan (changed + added + removed); new list = installed set.
        assertEq(ctmRegistry.facetList(OLD_VERSION).length, 3);
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

    function test_revertWhen_unknownKeyQueried() public {
        // The core registry answers implAddress only for contracts it lists.
        vm.expectRevert(RegistryUnknownKey.selector);
        coreRegistry.implAddress(EcosystemContract.L1Nullifier);

        // Only the new version's verifier is recorded: the old one is not this upgrade's data.
        vm.expectRevert(RegistryUnknownKey.selector);
        ctmRegistry.verifier(OLD_VERSION);

        vm.expectRevert(RegistryUnknownKey.selector);
        ctmRegistry.verifier(12345);

        // MailboxFacet is removed by this upgrade: it has no new-side row.
        vm.expectRevert(RegistryUnknownKey.selector);
        ctmRegistry.facetSelectors(CTMContract.MailboxFacet, NEW_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                     composition on generated data
    //////////////////////////////////////////////////////////////*/

    function test_buildFacetSwapPlan_plansExactlyThePlanRows() public view {
        UpgradeFacetSwap[] memory plan = RegistryFacetReader.facetSwapPlan(ICTMRegistry(address(ctmRegistry)));

        // The plan is exactly the old-side rows, in row order: AdminFacet changes address
        // (swap), MailboxFacet is removed, ExecutorFacet is added. GettersFacet is unchanged
        // and has no plan row, so no swap.
        assertEq(plan.length, 3);
        assertEq(plan[0].oldFacet, address(0xF101));
        assertEq(plan[0].newFacet, address(0xF201));
        assertFalse(plan[0].isFreezable);
        // The sample pins selector lists (the bootstrap override); they ride along verbatim.
        assertEq(plan[0].oldSelectors.length, 2);
        assertEq(plan[0].oldSelectors[0], bytes4(uint32(1)));
        assertEq(plan[0].newSelectors.length, 2);
        assertEq(plan[0].newSelectors[1], bytes4(uint32(3)));
        assertEq(plan[1].oldFacet, address(0xF103));
        assertEq(plan[1].newFacet, address(0)); // pure removal: no new address, no new selectors
        assertEq(plan[1].newSelectors.length, 0);
        assertEq(plan[1].oldSelectors.length, 1);
        assertEq(plan[2].oldFacet, address(0)); // pure addition: no old address, no old selectors
        assertEq(plan[2].oldSelectors.length, 0);
        assertEq(plan[2].newFacet, address(0xF203));
        assertEq(plan[2].newSelectors.length, 1);
        assertTrue(plan[2].isFreezable);
    }

    function test_buildUpgradeCutData_hasNoOuterFacetCuts() public pure {
        Diamond.DiamondCutData memory cut = CTMUpgradeComposer.buildUpgradeCutData(address(0xF205), hex"1234");

        assertEq(cut.initAddress, address(0xF205));
        assertEq(cut.initCalldata, hex"1234");
        // Facet swaps ride inside the init calldata's ProposedUpgrade.facetSwaps and are applied
        // by BaseZkSyncUpgrade itself; the committed cut carries no facet cuts at all.
        assertEq(cut.facetCuts.length, 0);
    }

    function test_buildL2UpgradeTx_matchesProtocolRequirements() public view {
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMRegistry(address(ctmRegistry))
        );

        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE);
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
        assertEq(
            uint256(deployments[0].upgradeType),
            uint256(IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade)
        );
        assertEq(deployments[0].deployedBytecodeInfo, hex"aa01");
        assertEq(delegateTo, address(0x00010004));
        assertEq(data, hex"beef");
    }

    function test_buildProposedUpgrade_pinsHashesAndVersion() public view {
        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(
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
        // The facet-swap plan is no longer in the ProposedUpgrade; it is composed separately via
        // buildFacetSwapPlan (asserted in test_buildFacetSwapPlan_plansExactlyThePlanRows) and
        // stored in the CTM, read back by BaseZkSyncUpgrade at execution.
    }

    function test_buildChainCreationParams_pinsRegistryAndBaseHashes() public view {
        ChainCreationParams memory params = CTMUpgradeComposer.buildChainCreationParams(
            ICTMRegistry(address(ctmRegistry))
        );

        assertEq(params.genesisUpgrade, address(0x00010005));
        assertEq(params.genesisIndexRepeatedStorageChanges, 54);
        assertEq(params.forceDeploymentsData, hex"f1f2");
        assertEq(params.diamondCut.initAddress, address(0xF204)); // DiamondInit
        // The genesis cut carries no facet cuts and NO init payload at all: DiamondInit reads
        // both the facet set and the base-system-contract hashes from the pinned registry.
        assertEq(params.diamondCut.facetCuts.length, 0);
        assertEq(params.diamondCut.initCalldata.length, 0);
        (bytes32 bootloaderHash, , ) = ctmRegistry.baseSystemContractHashes(ctmRegistry.newProtocolVersion());
        assertEq(bootloaderHash, bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000b00)));
        // The registry pinned for genesis is the registry itself — DiamondInit reads the facet
        // set straight from it (the same set the upgrade path's swap plan produces).
        assertEq(params.registry, address(ctmRegistry));

        // And that facet set (read via the shared reader) is AdminFacet(new) + GettersFacet +
        // ExecutorFacet, with the registry's pinned selector lists.
        FacetInstallation[] memory facets = RegistryFacetReader.newChainInstallations(
            ICTMRegistry(address(ctmRegistry))
        );
        assertEq(facets.length, 3);
        assertEq(facets[0].facet, address(0xF201));
        assertEq(facets[1].facet, address(0xF102));
        assertEq(facets[2].facet, address(0xF203));
        assertTrue(facets[2].isFreezable);
        assertEq(facets[0].selectors.length, 2);
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
