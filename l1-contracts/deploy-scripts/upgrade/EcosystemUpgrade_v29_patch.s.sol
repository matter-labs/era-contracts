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
        initialize(vm.envString("V29_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V29_UPGRADE_ECOSYSTEM_OUTPUT"));

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function deployNewEcosystemContractsL1() public override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

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

    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override returns (FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new FacetCut[](1);
        facetCuts[0] = FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
    }

    function prepareDefaultGovernanceCalls()
        public
        override
        returns (Call[] memory, Call[] memory stage1Calls, Call[] memory)
    {
        // We perform just the upgrade stage
        stage1Calls = prepareStage1GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1Calls));
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);

        allCalls[0] = prepareUpgradeProxiesCalls();
        allCalls[1] = prepareNewChainCreationParamsCall();
        allCalls[2] = prepareVersionSpecificStage1GovernanceCallsL1();
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

        Call[][] memory allCalls = new Call[][](3);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = prepareNewChainCreationParamsCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareCTMImplementationUpgrade(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[2] = prepareVersionSpecificStage1GovernanceCallsGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }
}
