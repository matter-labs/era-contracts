// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Action, FacetCut, StateTransitionDeployedAddresses, Utils} from "../Utils.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Call} from "contracts/governance/Common.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

/// @notice Script used for v29.1 stage patch
contract EcosystemUpgrade_v29_1 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    function run() public virtual override {
        initialize(vm.envString("V29_1_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V29_1_UPGRADE_ECOSYSTEM_OUTPUT"));

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();

        prepareTestCalls();
    }

    function initializeConfig(string memory newConfigPath) internal override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        addresses.stateTransition.diamondInit = toml.readAddress("$.state_transition.diamond_init_addr");
        addresses.stateTransition.executorFacet = toml.readAddress("$.state_transition.executor_facet_addr");
        addresses.stateTransition.genesisUpgrade = toml.readAddress("$.state_transition.genesis_upgrade_addr");
        addresses.stateTransition.gettersFacet = toml.readAddress("$.state_transition.getters_facet_addr");
        addresses.stateTransition.verifier = toml.readAddress("$.state_transition.verifier_addr");

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

        addresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        addresses.bridgehub.messageRootImplementation = deploySimpleContract("MessageRoot", false);
        addresses.stateTransition.adminFacet = deploySimpleContract("AdminFacet", false);
        addresses.stateTransition.mailboxFacet = deploySimpleContract("MailboxFacet", false);

        (
            addresses.bridgehub.chainAssetHandlerImplementation,
            addresses.bridgehub.chainAssetHandlerProxy
        ) = deployTuppWithContract("ChainAssetHandler", false);

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    function deployNewEcosystemContractsGW() public override {
        require(upgradeConfig.initialized, "Not initialized");

        gatewayConfig.gatewayStateTransition.adminFacet = deployGWContract("AdminFacet");
        gatewayConfig.gatewayStateTransition.mailboxFacet = deployGWContract("MailboxFacet");
        gatewayConfig.gatewayStateTransition.defaultUpgrade = deployUsedUpgradeContractGW();
    }

    /// @notice Get new facet cuts
    function getUpgradeFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal override returns (FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new FacetCut[](2);
        facetCuts[0] = FacetCut({
            facet: stateTransition.adminFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
    }

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion() internal override returns (Diamond.FacetCut[] memory facetCuts) {
        // Remove the old MailboxFacet
        facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public override returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = _buildCallProxyUpgrade(
            addresses.bridgehub.messageRootProxy,
            addresses.bridgehub.messageRootImplementation
        );
    }

    function prepareDAValidatorCall() public override returns (Call[] memory calls) {
        // Overriding it to be empty as this is not needed for the patch
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            data: abi.encodeCall(Bridgehub.setChainAssetHandler, (addresses.bridgehub.chainAssetHandlerProxy)),
            value: 0
        });
    }

    function prepareCTMImplementationUpgrade(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public override returns (Call[] memory calls) {
        // Overriding it to be empty as this is not needed for the patch
        return calls;
    }

    function prepareDAValidatorCallGW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public override returns (Call[] memory calls) {
        // Overriding it to be empty as this is not needed for the patch
        return calls;
    }

    // Tests patch upgrade by upgrading an existing chain
    function prepareTestCalls() public returns (Call[] memory calls) {
        Call[][] memory testCalls = new Call[][](1);

        testCalls[0] = prepareTestUpgradeChainCall();
        calls = mergeCallsArray(testCalls);

        string memory testCallsSerialized = vm.serializeBytes("governance_calls", "test_calls", abi.encode(calls));
        vm.writeToml(testCallsSerialized, upgradeConfig.outputPath, ".governance_calls");
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public override returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeEmptyUpgradeTx(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: stateTransition.verifier,
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ChainAssetHandler")) {
            if (!isZKBytecode) {
                return abi.encodeCall(ChainAssetHandler.initialize, (config.ownerAddress));
            } else {
                return
                    abi.encodeCall(
                        ChainAssetHandler.initialize,
                        AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress)
                    );
            }
        } else {
            return super.getInitializeCalldata(contractName, isZKBytecode);
        }
    }

    ////////////////////////////// Test utils /////////////////////////////////

    function prepareTestUpgradeChainCall() public returns (Call[] memory calls) {
        calls = new Call[](1);

        address chainDiamondProxyAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            config.gatewayChainId
        );
        uint256 oldProtocolVersion = getOldProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = generateUpgradeCutData(getAddresses().stateTransition);

        address admin = IZKChain(chainDiamondProxyAddress).getAdmin();
        console.log("Chain admin:", admin);

        calls[0] = Call({
            target: chainDiamondProxyAddress,
            data: abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            value: 0
        });
    }
}
