// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CTMUpgradeV34Harness} from "foundry-test/l1/integration/utils/CTMUpgradeV34Harness.sol";
import {UpgradeHelperLib} from "deploy-scripts/upgrade/default-upgrade/UpgradeHelperLib.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Call} from "contracts/governance/Common.sol";
import {TEST_CHAIN_CONFIG_UPGRADE_VERSION} from "../../../../TestConstants.sol";

contract V34UpgradeScriptTest is Test {
    // The v34 cut runs V34UpgradeZKsyncOS (the default upgrade plus the gas-limit clamp), while the CTM's
    // reusable default upgrade stays DefaultUpgradeZKsyncOS for later releases.
    function test_CutUsesV34UpgradeAndKeepsDefault() public {
        CTMUpgradeV34Harness script = new CTMUpgradeV34Harness();
        address ctm = makeAddr("ctm");
        address chain = makeAddr("chain");
        uint256 version = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);

        // Only discovery calls are mocked; both upgrade implementations are deployed by the script.
        vm.mockCall(chain, abi.encodeCall(IGetters.facets, ()), abi.encode(new IZKChain.Facet[](0)));
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(version));
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainTypeManager, ()), abi.encode(ctm));
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.protocolVersion, ()), abi.encode(version));
        script.setForceDeploymentsInputs(makeAddr("ctmDeploymentTracker"), hex"c0ffee");

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
            cut.initAddress.code,
            BytecodeUtils.readDeployedBytecodeL1("V34UpgradeZKsyncOS.sol", "V34UpgradeZKsyncOS")
        );
        assertEq(
            stateTransition.defaultUpgrade.code,
            BytecodeUtils.readDeployedBytecodeL1("DefaultUpgradeZKsyncOS.sol", "DefaultUpgradeZKsyncOS")
        );
        assertNotEq(cut.initAddress, stateTransition.defaultUpgrade);

        Call[] memory calls = script.prepareSetDefaultUpgradeCall();
        assertEq(calls.length, 1);
        assertEq(calls[0].target, ctm);
        assertEq(calls[0].data, abi.encodeCall(IChainTypeManager.setDefaultUpgrade, (stateTransition.defaultUpgrade)));

        ProposedUpgrade memory proposal = script.getProposedUpgrade(
            chainCreationParams,
            factoryDeps,
            UpgradeHelperLib.getProtocolUpgradeNonce(version)
        );
        assertEq(cut.initCalldata, abi.encodeCall(DefaultUpgrade.upgrade, (proposal)));
    }
}
