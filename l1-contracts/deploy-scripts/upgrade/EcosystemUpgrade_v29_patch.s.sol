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
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Call} from "contracts/governance/Common.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

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

        prepareTestCalls();
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

        addresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        addresses.bridgehub.messageRootImplementation = deploySimpleContract("MessageRoot", false);
        addresses.stateTransition.adminFacet = deploySimpleContract("AdminFacet", false);
        addresses.stateTransition.mailboxFacet = deploySimpleContract("MailboxFacet", false);

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    function deployNewEcosystemContractsGW() public override {
        require(upgradeConfig.initialized, "Not initialized");

        gatewayConfig.gatewayStateTransition.adminFacet = deployGWContract("AdminFacet");
        gatewayConfig.gatewayStateTransition.mailboxFacet = deployGWContract("MailboxFacet");
        gatewayConfig.gatewayStateTransition.defaultUpgrade = deployUsedUpgradeContractGW();
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

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](6);

        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        allCalls[2] = prepareUpgradeProxiesCalls();
        allCalls[3] = prepareNewChainCreationParamsCall();
        allCalls[4] = provideSetNewVersionUpgradeCall();
        allCalls[5] = prepareGatewaySpecificStage1GovernanceCalls();

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

        Call[][] memory allCalls = new Call[][](2);

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        allCalls[0] = provideSetNewVersionUpgradeCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareNewChainCreationParamsCallForGateway(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }

    // Tests patch upgrade by upgrading a chain and deploying a new one
    function prepareTestCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory testCalls = new Call[][](1);

        testCalls[0] = prepareTestUpgradeChainCall();
        calls = mergeCallsArray(testCalls);

        string memory testCallsSerialized = vm.serializeBytes("governance_calls", "test_calls", abi.encode(calls));
        vm.writeToml(testCallsSerialized, upgradeConfig.outputPath, ".governance_calls");
    }

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

    /// @notice Build empty L1 -> L2 upgrade tx
    function _composeEmptyUpgradeTx() internal virtual returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            txType: 0,
            from: uint256(0),
            to: uint256(0),
            gasLimit: 0,
            gasPerPubdataByteLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: 0,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: new bytes(0),
            signature: new bytes(0),
            factoryDeps: new uint256[](0),
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    function publishBytecodes() public override {
        bytes[] memory allDeps = getFullListOfFactoryDependencies();
        uint256[] memory factoryDeps = new uint256[](allDeps.length);
        require(factoryDeps.length <= 64, "Too many deps");

        BytecodePublisher.publishBytecodesInBatches(
            BytecodesSupplier(addresses.stateTransition.bytecodesSupplier),
            allDeps
        );

        for (uint256 i = 0; i < allDeps.length; i++) {
            bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(allDeps[i]);
            factoryDeps[i] = uint256(bytecodeHash);
            isHashInFactoryDeps[bytecodeHash] = true;
        }

        // This check is removed as we set these hashes to bytes32(0), given that this is a patch upgrade
        // Double check for consistency:
        // require(bytes32(factoryDeps[0]) == config.contracts.bootloaderHash, "bootloader hash factory dep mismatch");
        // require(bytes32(factoryDeps[1]) == config.contracts.defaultAAHash, "default aa hash factory dep mismatch");
        // require(bytes32(factoryDeps[2]) == config.contracts.evmEmulatorHash, "EVM emulator hash factory dep mismatch");

        factoryDepsHashes = factoryDeps;

        upgradeConfig.factoryDepsPublished = true;
    }
}
