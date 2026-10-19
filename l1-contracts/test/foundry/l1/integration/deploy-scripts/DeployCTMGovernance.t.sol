// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {DeployL1CoreContractsIntegrationScript} from "./DeployL1CoreContractsIntegration.s.sol";
import {DeployCTMIntegrationScript} from "./DeployCTMIntegration.s.sol";
import {CoreDeployedAddresses} from "deploy-scripts/ecosystem/DeployL1CoreUtils.s.sol";
import {CTMDeployedAddresses} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

/// @dev `DeployCTM` without `reuseGovAndAdmin`, its own `Governance` landing apart from the ecosystem's: with the
///      harness config both CREATE2 to one address, so only the minimum delay is changed.
contract DeployCTMWithOwnGovernanceScript is DeployCTMIntegrationScript {
    uint256 internal constant CTM_GOVERNANCE_MIN_DELAY = 1;

    function initializeConfig(string memory _configPath) internal override {
        super.initializeConfig(_configPath);
        config.contracts.governanceMinDelay = CTM_GOVERNANCE_MIN_DELAY;
    }
}

/// @notice The genesis force deployments a fresh CTM pins name the ECOSYSTEM governance — the one its CTM executor
///         is nominated to and protocol-ops' force-deployments check expects — even when the CTM has a governance of
///         its own.
contract DeployCTMGovernanceTest is Test {
    string internal constant CTM_OUTPUT =
        "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm-own-governance.toml";

    DeployL1CoreContractsIntegrationScript internal l1Script;
    DeployCTMWithOwnGovernanceScript internal ctmScript;
    CoreDeployedAddresses internal ecosystem;
    address internal coreExecutor;

    function setUp() public {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv("CTM_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml");
        vm.setEnv("CTM_OUTPUT", CTM_OUTPUT);
        vm.setEnv(
            "PERMANENT_VALUES_INPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-config/permanent-values.toml"
        );
        l1Script = new DeployL1CoreContractsIntegrationScript();
        l1Script.runForTest();
        ecosystem = l1Script.getAddresses();
        coreExecutor = l1Script.getUpgradeExecutor().coreExecutor;
        ctmScript = new DeployCTMWithOwnGovernanceScript();
    }

    /// @notice A fresh init deploys the CTM while governance's nomination on the core executor is still outstanding:
    ///         the deployer still owns the executor, and must not be taken for the governance.
    function test_ownGovernance_forceDeploymentsPinTheNominatedEcosystemGovernance() public {
        assertEq(Ownable2Step(coreExecutor).pendingOwner(), ecosystem.shared.governance, "nomination outstanding");
        assertEq(Ownable2Step(coreExecutor).owner(), l1Script.getDeployerAddress(), "the deployer still owns it");

        ctmScript.runForAnvilTest(ecosystem.bridgehub.proxies.bridgehub);

        _assertPinsTheEcosystemGovernance();
    }

    /// @notice A CTM deployed after governance accepted the core executor pins the same governance.
    function test_ownGovernance_forceDeploymentsPinTheAcceptedEcosystemGovernance() public {
        vm.prank(ecosystem.shared.governance);
        Ownable2Step(coreExecutor).acceptOwnership();

        ctmScript.runForAnvilTest(ecosystem.bridgehub.proxies.bridgehub);

        _assertPinsTheEcosystemGovernance();
    }

    /// @notice Without a core executor holding the ecosystem ProxyAdmin there is no ecosystem governance to pin,
    ///         and the deployment refuses before building the force deployments.
    function test_ecosystemWithoutCoreExecutor_isRefused() public {
        Call[] memory release = new Call[](1);
        release[0] = Call({
            target: ecosystem.shared.transparentProxyAdmin,
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (makeAddr("preRegistryOwner")))
        });
        vm.prank(l1Script.getDeployerAddress());
        CoreUpgradeExecutor(payable(coreExecutor)).forward(release);

        vm.expectRevert(
            "the ecosystem ProxyAdmin is not held by a CoreUpgradeExecutor: the ecosystem predates the registry model"
        );
        ctmScript.runForAnvilTest(ecosystem.bridgehub.proxies.bridgehub);
    }

    function _assertPinsTheEcosystemGovernance() internal view {
        address governance = ecosystem.shared.governance;
        CTMDeployedAddresses memory ctm = ctmScript.getAddresses();
        assertTrue(ctm.admin.governance != governance, "the CTM has a governance of its own");
        assertTrue(ctm.admin.governance.code.length != 0, "and it is deployed");

        bytes memory pinned = ICTMRelease(
            IChainTypeManager(ctm.stateTransition.proxies.chainTypeManager).currentRelease()
        ).fixedForceDeploymentsData();
        FixedForceDeploymentsData memory data = abi.decode(pinned, (FixedForceDeploymentsData));
        assertEq(
            data.aliasedL1Governance,
            AddressAliasHelper.applyL1ToL2Alias(governance),
            "the release pins the ecosystem governance"
        );

        string memory output = vm.readFile(string.concat(vm.projectRoot(), CTM_OUTPUT));
        assertEq(
            vm.parseTomlBytes(output, "$.contracts_config.force_deployments_data"),
            pinned,
            "the output carries the pinned blob"
        );
        assertEq(
            Ownable2Step(ctmScript.getCTMUpgradeExecutor().ctmExecutor).pendingOwner(),
            governance,
            "the CTM executor is nominated to the same governance"
        );
    }
}
