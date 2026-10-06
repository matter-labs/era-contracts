// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CTMUpgradeHarness} from "foundry-test/l1/integration/utils/CTMUpgradeHarness.sol";
import {UpgradeHelperLib} from "deploy-scripts/upgrade/default-upgrade/UpgradeHelperLib.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2DefaultUpgrade} from "contracts/upgrades/IL2DefaultUpgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TEST_CHAIN_CONFIG_UPGRADE_VERSION} from "../../../../TestConstants.sol";

contract DefaultCTMUpgradeScriptTest is Test {
    // The v34 upgrade is the default one: the cut runs the CTM's default `DefaultUpgradeZKsyncOS`, and the
    // L2 transaction delegates to `L2DefaultUpgrade`.
    function test_CutUsesDefaultUpgradeAndL2DefaultUpgrade() public {
        CTMUpgradeHarness script = new CTMUpgradeHarness();
        address ctm = makeAddr("ctm");
        address chain = makeAddr("chain");
        uint256 version = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);

        // Only discovery calls are mocked; the upgrade implementation is deployed by the script.
        vm.mockCall(chain, abi.encodeCall(IGetters.facets, ()), abi.encode(new IZKChain.Facet[](0)));
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(version));
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainTypeManager, ()), abi.encode(ctm));
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.protocolVersion, ()), abi.encode(version));

        address ctmDeploymentTracker = makeAddr("ctmDeploymentTracker");
        bytes memory fixedForceDeploymentsData = hex"c0ffee";
        script.setForceDeploymentsInputs(ctmDeploymentTracker, fixedForceDeploymentsData);

        StateTransitionDeployedAddresses memory stateTransition;
        stateTransition.defaultUpgrade = script.deployDefaultUpgrade(ctm);
        ChainCreationParamsConfig memory chainCreationParams;
        chainCreationParams.latestProtocolVersion = version;
        PublishFactoryDepsResult memory factoryDeps;

        Diamond.DiamondCutData memory cut = script.generateUpgradeCutData(
            stateTransition,
            chainCreationParams,
            factoryDeps,
            chain
        );
        // Scripts load artifacts from disk; coverage compiles inline runtimeCode with different settings.
        assertEq(
            stateTransition.defaultUpgrade.code,
            BytecodeUtils.readDeployedBytecodeL1("DefaultUpgradeZKsyncOS.sol", "DefaultUpgradeZKsyncOS")
        );
        assertEq(cut.initAddress, stateTransition.defaultUpgrade);

        Call[] memory calls = script.prepareSetDefaultUpgradeCall();
        assertEq(calls.length, 1);
        assertEq(calls[0].target, ctm);
        assertEq(calls[0].value, 0);
        assertEq(calls[0].data, abi.encodeCall(IChainTypeManager.setDefaultUpgrade, (stateTransition.defaultUpgrade)));

        ProposedUpgrade memory proposal = script.getProposedUpgrade(
            chainCreationParams,
            factoryDeps,
            UpgradeHelperLib.getProtocolUpgradeNonce(version)
        );
        assertEq(proposal.l2ProtocolUpgradeTx.nonce, uint256(TEST_CHAIN_CONFIG_UPGRADE_VERSION));
        Diamond.DiamondCutData memory repeatedCut = script.generateUpgradeCutData(
            stateTransition,
            chainCreationParams,
            factoryDeps,
            chain
        );
        assertEq(repeatedCut.initAddress, cut.initAddress);
        assertEq(repeatedCut.initCalldata, cut.initCalldata);
        assertEq(cut.initCalldata, abi.encodeCall(DefaultUpgrade.upgrade, (proposal)));
        assertEq(proposal.l2ProtocolUpgradeTx.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));

        // The L2 tx force-deploys L2DefaultUpgrade and delegates to it with the placeholder per-chain data,
        // which DefaultUpgradeZKsyncOS rewrites per chain.
        bytes memory delegateBytecodeInfo = Utils.getZKOSBytecodeInfoForContract(
            "L2DefaultUpgrade.sol",
            "L2DefaultUpgrade"
        );
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(delegateBytecodeInfo);
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory expectedDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        expectedDeployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: delegateBytecodeInfo,
            newAddress: delegateTo
        });
        assertNotEq(delegateTo, address(0));
        assertEq(
            proposal.l2ProtocolUpgradeTx.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (
                    expectedDeployments,
                    delegateTo,
                    abi.encodeCall(IL2DefaultUpgrade.upgrade, (ctmDeploymentTracker, fixedForceDeploymentsData, ""))
                )
            )
        );
    }
}
