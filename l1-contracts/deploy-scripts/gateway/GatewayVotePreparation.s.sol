// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {Utils} from "../utils/Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {Call} from "contracts/governance/Common.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";

import {DeployCTMScript} from "../ctm/DeployCTM.s.sol";
import {StateTransitionDeployedAddresses, StateTransitionContracts, Verifiers, Facets} from "../utils/Types.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";

import {GatewayCTMDeployerHelper, DeployerCreate2Calldata, DeployerAddresses, DirectDeployedAddresses, DirectCreate2Calldata} from "./GatewayCTMDeployerHelper.sol";
import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {GatewayGovernanceUtils} from "./GatewayGovernanceUtils.s.sol";
import {DeployCTMUtils} from "../ctm/DeployCTMUtils.s.sol";
import {BridgehubAddresses, CTMDeployedAddresses} from "../utils/Types.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayVotePreparation is DeployCTMUtils, GatewayGovernanceUtils {
    using stdToml for string;

    CTMDeployedAddresses internal addresses;

    struct GatewayCTMOutput {
        StateTransitionDeployedAddresses gatewayStateTransition;
        address multicall3;
        bytes diamondCutData;
        address relayedSLDAValidator;
        address validiumDAValidator;
        address rollupDAManager;
    }

    GatewayCTMOutput internal output;

    uint256 constant EXPECTED_MAX_L1_GAS_PRICE = 50 gwei;

    uint256 internal eraChainId;

    uint256 internal gatewayChainId;
    bytes internal forceDeploymentsData;

    address internal serverNotifier;
    address internal refundRecipient;
    address ctm;

    GatewayCTMDeployerConfig internal gatewayCTMDeployerConfig;

    function initializeConfig(
        string memory configPath,
        string memory permanentValuesPath,
        address bridgehubProxy,
        uint256 ctmRepresentativeChainId
    ) internal virtual {
        super.initializeConfig(configPath, permanentValuesPath, bridgehubProxy);
        string memory toml = vm.readFile(configPath);

        refundRecipient = toml.readAddress("$.refund_recipient");

        gatewayChainId = toml.readUint("$.gateway_chain_id");
        forceDeploymentsData = toml.readBytes(".force_deployments_data");

        setAddressesBasedOnBridgehub(ctmRepresentativeChainId, bridgehubProxy);
        // Get eraChainId from AssetRouter
        address assetRouter = address(IL1Bridgehub(bridgehubProxy).assetRouter());
        eraChainId = AddressIntrospector.getEraChainId(assetRouter);

        address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);
        gatewayCTMDeployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: aliasedGovernor,
            salt: bytes32(0),
            eraChainId: config.eraChainId,
            l1ChainId: config.l1ChainId,
            testnetVerifier: config.testnetVerifier,
            isZKsyncOS: config.isZKsyncOS,
            adminSelectors: Utils.getAllSelectorsForFacet("Admin"),
            executorSelectors: Utils.getAllSelectorsForFacet("Executor"),
            mailboxSelectors: Utils.getAllSelectorsForFacet("Mailbox"),
            gettersSelectors: Utils.getAllSelectorsForFacet("Getters"),
            bootloaderHash: config.contracts.chainCreationParams.bootloaderHash,
            defaultAccountHash: config.contracts.chainCreationParams.defaultAAHash,
            evmEmulatorHash: config.contracts.chainCreationParams.evmEmulatorHash,
            genesisRoot: config.contracts.chainCreationParams.genesisRoot,
            genesisRollupLeafIndex: uint64(config.contracts.chainCreationParams.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.chainCreationParams.genesisBatchCommitment,
            forceDeploymentsData: forceDeploymentsData,
            protocolVersion: config.contracts.chainCreationParams.latestProtocolVersion
        });
    }

    function setAddressesBasedOnBridgehub(uint256 ctmRepresentativeChainId, address bridgehubProxy) internal {
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubProxy);
        config.ownerAddress = L1Bridgehub(bridgehubProxy).owner();
        if (ctmRepresentativeChainId != 0) {
            ctm = IL1Bridgehub(bridgehubProxy).chainTypeManager(ctmRepresentativeChainId);
        } else {
            ctm = IL1Bridgehub(bridgehubProxy).chainTypeManager(gatewayChainId);
        }
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        require(
            ctmProtocolVersion == config.contracts.chainCreationParams.latestProtocolVersion,
            "CTM protocol version mismatch"
        );
        // Get full CTM addresses including stateTransition info
        addresses = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
        // Override chainAdmin with the bridgehub admin (ecosystem admin)
        addresses.chainAdmin = L1Bridgehub(bridgehubProxy).admin();
    }

    function deployGatewayCTM() internal {
        (
            DeployedContracts memory expectedGatewayContracts,
            DeployerCreate2Calldata memory deployerCalldata,
            ,
            DirectCreate2Calldata memory directCalldata,
            address create2FactoryAddress
        ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), gatewayCTMDeployerConfig);

        // Deploy all factory dependencies
        bytes[] memory deps = GatewayCTMDeployerHelper.getListOfFactoryDeps(gatewayCTMDeployerConfig.isZKsyncOS);
        address l1AssetRouter = address(IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).assetRouter());

        for (uint i = 0; i < deps.length; i++) {
            bytes[] memory localDeps = new bytes[](1);
            localDeps[0] = deps[i];
            runGatewayL1L2TransactionWithFactoryDeps(address(0), hex"", localDeps);
        }

        // Deploy DA contracts (RollupDAManager, ValidiumL1DAValidator, RelayedSLDAValidator)
        runGatewayL1L2Transaction(create2FactoryAddress, deployerCalldata.daCalldata);

        // Deploy ProxyAdmin
        runGatewayL1L2Transaction(create2FactoryAddress, deployerCalldata.proxyAdminCalldata);

        // Deploy ValidatorTimelock (implementation + proxy)
        runGatewayL1L2Transaction(create2FactoryAddress, deployerCalldata.validatorTimelockCalldata);

        // Deploy Verifiers (Era or ZKsyncOS verifiers based on config)
        runGatewayL1L2Transaction(create2FactoryAddress, deployerCalldata.verifiersCalldata);

        // Deploy direct contracts (AdminFacet, MailboxFacet, ExecutorFacet, GettersFacet,
        // DiamondInit, L1GenesisUpgrade, Multicall3)
        _deployDirectContracts(directCalldata, create2FactoryAddress);

        // Deploy CTM and ServerNotifier (Era or ZKsyncOS CTM based on config)
        runGatewayL1L2Transaction(create2FactoryAddress, deployerCalldata.ctmCalldata);

        _saveExpectedGatewayContractsToOutput(expectedGatewayContracts);
    }

    function _deployDirectContracts(DirectCreate2Calldata memory directCalldata, address targetAddr) internal {
        // Deploy AdminFacet
        runGatewayL1L2Transaction(targetAddr, directCalldata.adminFacetCalldata);

        // Deploy MailboxFacet
        runGatewayL1L2Transaction(targetAddr, directCalldata.mailboxFacetCalldata);

        // Deploy ExecutorFacet
        runGatewayL1L2Transaction(targetAddr, directCalldata.executorFacetCalldata);

        // Deploy GettersFacet
        runGatewayL1L2Transaction(targetAddr, directCalldata.gettersFacetCalldata);

        // Deploy DiamondInit
        runGatewayL1L2Transaction(targetAddr, directCalldata.diamondInitCalldata);

        // Deploy L1GenesisUpgrade
        runGatewayL1L2Transaction(targetAddr, directCalldata.genesisUpgradeCalldata);

        // Deploy Multicall3
        runGatewayL1L2Transaction(targetAddr, directCalldata.multicall3Calldata);
    }

    function runGatewayL1L2TransactionWithFactoryDeps(
        address to,
        bytes memory data,
        bytes[] memory factoryDeps
    ) internal {
        Utils.runL1L2Transaction({
            l2Calldata: data,
            l2GasLimit: 72_000_000,
            l2Value: 0,
            factoryDeps: factoryDeps,
            dstAddress: to,
            chainId: gatewayChainId,
            bridgehubAddress: coreAddresses.bridgehub.proxies.bridgehub,
            l1SharedBridgeProxy: coreAddresses.bridges.proxies.l1AssetRouter,
            refundRecipient: msg.sender
        });
    }

    function runGatewayL1L2Transaction(address to, bytes memory data) internal {
        runGatewayL1L2TransactionWithFactoryDeps(to, data, new bytes[](0));
    }

    function _saveExpectedGatewayContractsToOutput(DeployedContracts memory expectedGatewayContracts) internal {
        output = GatewayCTMOutput({
            gatewayStateTransition: StateTransitionDeployedAddresses({
                proxies: StateTransitionContracts({
                    chainTypeManager: expectedGatewayContracts.stateTransition.chainTypeManagerProxy,
                    serverNotifier: expectedGatewayContracts.stateTransition.serverNotifierProxy,
                    validatorTimelock: expectedGatewayContracts.stateTransition.validatorTimelockProxy
                }),
                implementations: StateTransitionContracts({
                    chainTypeManager: expectedGatewayContracts.stateTransition.chainTypeManagerImplementation,
                    serverNotifier: expectedGatewayContracts.stateTransition.serverNotifierImplementation,
                    validatorTimelock: expectedGatewayContracts.stateTransition.validatorTimelockImplementation
                }),
                verifiers: expectedGatewayContracts.stateTransition.verifiers,
                facets: expectedGatewayContracts.stateTransition.facets,
                genesisUpgrade: expectedGatewayContracts.stateTransition.genesisUpgrade,
                defaultUpgrade: address(0),
                legacyValidatorTimelock: address(0),
                eraDiamondProxy: address(0),
                rollupDAManager: expectedGatewayContracts.daContracts.rollupDAManager,
                rollupSLDAValidator: expectedGatewayContracts.daContracts.relayedSLDAValidator
            }),
            multicall3: expectedGatewayContracts.multicall3,
            diamondCutData: expectedGatewayContracts.diamondCutData,
            relayedSLDAValidator: expectedGatewayContracts.daContracts.relayedSLDAValidator,
            validiumDAValidator: expectedGatewayContracts.daContracts.validiumDAValidator,
            rollupDAManager: expectedGatewayContracts.daContracts.rollupDAManager
        });
    }

    function run(address bridgehubProxy, uint256 ctmRepresentativeChainId) public {
        prepareForGWVoting(bridgehubProxy, ctmRepresentativeChainId);
    }

    function deployServerNotifier() internal returns (address implementation, address proxy) {
        // We will not store the address of the ProxyAdmin as it is trivial to query if needed.
        address ecosystemProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.chainAdmin, false);

        (implementation, proxy) = deployTuppWithContractAndProxyAdmin("ServerNotifier", ecosystemProxyAdmin, false);
    }

    function prepareForGWVoting(address bridgehubProxy, uint256 ctmRepresentativeChainId) public {
        console.log("Setting up the Gateway script");

        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("GATEWAY_VOTE_PREPARATION_INPUT"));
        string memory permanentValuesPath = string.concat(root, vm.envString("PERMANENT_VALUES_INPUT"));

        initializeConfig(configPath, permanentValuesPath, bridgehubProxy, ctmRepresentativeChainId);
        _initializeGatewayGovernanceConfig(
            GatewayGovernanceConfig({
                bridgehubProxy: coreAddresses.bridgehub.proxies.bridgehub,
                l1AssetRouterProxy: address(IL1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).assetRouter()),
                chainTypeManagerProxy: ctm,
                ctmDeploymentTrackerProxy: coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                gatewayChainId: gatewayChainId
            })
        );
        instantiateCreate2Factory();

        Call[] memory ecosystemAdminCalls;
        if (serverNotifier == address(0)) {
            (, serverNotifier) = deployServerNotifier();

            vm.startBroadcast();
            ServerNotifier(serverNotifier).setChainTypeManager(IChainTypeManager(ctm));
            ServerNotifier(serverNotifier).transferOwnership(addresses.chainAdmin);
            vm.stopBroadcast();

            ecosystemAdminCalls = new Call[](2);
            ecosystemAdminCalls[0] = Call({
                target: addresses.stateTransition.proxies.chainTypeManager,
                value: 0,
                data: abi.encodeCall(ChainTypeManagerBase.setServerNotifier, (serverNotifier))
            });
            ecosystemAdminCalls[1] = Call({
                target: serverNotifier,
                value: 0,
                data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
            });
        }

        // Firstly, we deploy Gateway CTM
        deployGatewayCTM();

        Call[] memory governanceCalls = _prepareGatewayGovernanceCalls(
            PrepareGatewayGovernanceCalls({
                _l1GasPrice: EXPECTED_MAX_L1_GAS_PRICE,
                _gatewayCTMAddress: output.gatewayStateTransition.proxies.chainTypeManager,
                _gatewayRollupDAManager: output.rollupDAManager,
                _gatewayValidatorTimelock: output.gatewayStateTransition.proxies.validatorTimelock,
                _gatewayServerNotifier: output.gatewayStateTransition.proxies.serverNotifier,
                _refundRecipient: refundRecipient,
                _ctmRepresentativeChainId: ctmRepresentativeChainId
            })
        );

        saveOutput(governanceCalls, ecosystemAdminCalls);
    }

    function saveOutput(Call[] memory governanceCallsToExecute, Call[] memory ecosystemAdminCallsToExecute) internal {
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy_addr",
            output.gatewayStateTransition.proxies.chainTypeManager
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_implementation_addr",
            output.gatewayStateTransition.implementations.chainTypeManager
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "verifier_addr",
            output.gatewayStateTransition.verifiers.verifier
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "admin_facet_addr",
            output.gatewayStateTransition.facets.adminFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "mailbox_facet_addr",
            output.gatewayStateTransition.facets.mailboxFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "executor_facet_addr",
            output.gatewayStateTransition.facets.executorFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "getters_facet_addr",
            output.gatewayStateTransition.facets.gettersFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "diamond_init_addr",
            output.gatewayStateTransition.facets.diamondInit
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "genesis_upgrade_addr",
            output.gatewayStateTransition.genesisUpgrade
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "default_upgrade_addr",
            output.gatewayStateTransition.defaultUpgrade
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "validator_timelock_addr",
            output.gatewayStateTransition.proxies.validatorTimelock
        );
        vm.serializeAddress("gateway_state_transition", "rollup_da_manager_addr", output.rollupDAManager);
        string memory gatewayStateTransition = vm.serializeAddress(
            "gateway_state_transition",
            "diamond_proxy_addr",
            output.gatewayStateTransition.eraDiamondProxy
        );
        vm.serializeString("root", "gateway_state_transition", gatewayStateTransition);
        vm.serializeAddress("root", "multicall3_addr", output.multicall3);
        vm.serializeAddress("root", "relayed_sl_da_validator", output.relayedSLDAValidator);
        vm.serializeAddress("root", "validium_da_validator", output.validiumDAValidator);
        vm.serializeBytes("root", "governance_calls_to_execute", abi.encode(governanceCallsToExecute));
        vm.serializeBytes("root", "ecosystem_admin_calls_to_execute", abi.encode(ecosystemAdminCallsToExecute));

        string memory toml = vm.serializeBytes("root", "diamond_cut_data", output.diamondCutData);
        string memory path = string.concat(vm.projectRoot(), vm.envString("GATEWAY_VOTE_PREPARATION_OUTPUT"));
        vm.writeToml(toml, path);
    }
}
