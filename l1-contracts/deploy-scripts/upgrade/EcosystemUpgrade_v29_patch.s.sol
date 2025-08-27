// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Action, FacetCut, StateTransitionDeployedAddresses, Utils} from "../Utils.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Call} from "contracts/governance/Common.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

/// @notice Script used for v29 stage patch
contract EcosystemUpgrade_v29_patch is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    function run() public virtual override {
        initialize(
            vm.envString("V29_PATCH_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("V29_PATCH_UPGRADE_ECOSYSTEM_OUTPUT")
        );

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function initializeConfig(string memory newConfigPath) internal override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        addresses.stateTransition.adminFacet = toml.readAddress("$.state_transition.admin_facet_addr");
        addresses.stateTransition.diamondInit = toml.readAddress("$.state_transition.diamond_init_addr");
        addresses.stateTransition.executorFacet = toml.readAddress("$.state_transition.executor_facet_addr");
        addresses.stateTransition.genesisUpgrade = toml.readAddress("$.state_transition.genesis_upgrade_addr");
        addresses.stateTransition.gettersFacet = toml.readAddress("$.state_transition.getters_facet_addr");
        addresses.stateTransition.verifier = toml.readAddress("$.state_transition.verifier_addr");

        gatewayConfig.gatewayStateTransition.adminFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.admin_facet_addr"
        );
        gatewayConfig.gatewayStateTransition.diamondInit = toml.readAddress(
            "$.gateway.gateway_state_transition.diamond_init_addr"
        );
        gatewayConfig.gatewayStateTransition.executorFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.executor_facet_addr"
        );
        gatewayConfig.gatewayStateTransition.genesisUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.genesis_upgrade_addr"
        );
        gatewayConfig.gatewayStateTransition.gettersFacet = toml.readAddress(
            "$.gateway.gateway_state_transition.getters_facet_addr"
        );
        gatewayConfig.gatewayStateTransition.verifier = toml.readAddress(
            "$.gateway.gateway_state_transition.verifier_addr"
        );
    }

    function deployNewEcosystemContractsL1() public override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();
        deployUpgradeStageValidator();

        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        addresses.bridgehub.messageRootImplementation = deploySimpleContract("MessageRoot", false);
        addresses.stateTransition.mailboxFacet = deploySimpleContract("MailboxFacet", false);

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    function deployNewEcosystemContractsGW() public override {
        require(upgradeConfig.initialized, "Not initialized");
        gatewayConfig.gatewayStateTransition.mailboxFacet = deployGWContract("MailboxFacet");
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal override returns (Diamond.FacetCut[] memory facetCuts) {
        // Remove the old MailboxFacet
        facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);

        allCalls[0] = prepareUpgradeProxiesCalls();
        allCalls[1] = prepareNewChainCreationParamsCall();
        allCalls[2] = provideSetNewVersionUpgradeCall();
        allCalls[3] = prepareGatewaySpecificStage1GovernanceCalls();

        calls = mergeCallsArray(allCalls);
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public override returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = _buildCallProxyUpgrade(
            addresses.bridgehub.messageRootProxy,
            addresses.bridgehub.messageRootImplementation
        );
    }

    function prepareGatewaySpecificStage1GovernanceCalls() public override returns (Call[] memory calls) {
        if (gatewayConfig.chainId == 0) return calls; // Gateway is unknown

        Call[][] memory allCalls = new Call[][](1);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = prepareNewChainCreationParamsCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }
}
