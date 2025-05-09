// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_CREATE2_FACTORY_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L2AssetRouter, IL2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

import {DeployL1Script} from "./DeployL1.s.sol";

import {GatewayCTMDeployerHelper} from "./GatewayCTMDeployerHelper.sol";
import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {GatewayGovernanceUtils} from "./GatewayGovernanceUtils.s.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayVotePreparation is DeployL1Script, GatewayGovernanceUtils {
    using stdToml for string;

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

    address internal rollupL2DAValidator;
    address internal oldRollupL2DAValidator;

    uint256 internal gatewayChainId;
    bytes internal forceDeploymentsData;

    address internal serverNotifier;
    address internal refundRecipient;

    GatewayCTMDeployerConfig internal gatewayCTMDeployerConfig;

    function initializeConfig(string memory configPath) internal virtual override {
        super.initializeConfig(configPath);
        string memory toml = vm.readFile(configPath);

        addresses.bridgehub.bridgehubProxy = toml.readAddress("$.contracts.bridgehub_proxy_address");
        refundRecipient = toml.readAddress("$.refund_recipient");

        // The "new" and "old" rollup L2 DA validators are those that were set in v27 and v26 respectively
        rollupL2DAValidator = toml.readAddress("$.rollup_l2_da_validator");
        oldRollupL2DAValidator = toml.readAddress("$.old_rollup_l2_da_validator");

        gatewayChainId = toml.readUint("$.gateway_chain_id");
        forceDeploymentsData = toml.readBytes(".force_deployments_data");

        setAddressesBasedOnBridgehub();

        address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress);
        gatewayCTMDeployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: aliasedGovernor,
            salt: bytes32(0),
            eraChainId: config.eraChainId,
            l1ChainId: config.l1ChainId,
            rollupL2DAValidatorAddress: rollupL2DAValidator,
            testnetVerifier: config.testnetVerifier,
            adminSelectors: Utils.getAllSelectorsForFacet("Admin"),
            executorSelectors: Utils.getAllSelectorsForFacet("Executor"),
            mailboxSelectors: Utils.getAllSelectorsForFacet("Mailbox"),
            gettersSelectors: Utils.getAllSelectorsForFacet("Getters"),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
                recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
                recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
            }),
            feeParams: FeeParams({
                pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
                batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
                maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
                maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
                priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
                minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
            }),
            bootloaderHash: config.contracts.bootloaderHash,
            defaultAccountHash: config.contracts.defaultAAHash,
            evmEmulatorHash: config.contracts.evmEmulatorHash,
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            genesisRoot: config.contracts.genesisRoot,
            genesisRollupLeafIndex: uint64(config.contracts.genesisRollupLeafIndex),
            genesisBatchCommitment: config.contracts.genesisBatchCommitment,
            forceDeploymentsData: forceDeploymentsData,
            protocolVersion: config.contracts.latestProtocolVersion
        });
    }

    function setAddressesBasedOnBridgehub() internal {
        config.ownerAddress = Bridgehub(addresses.bridgehub.bridgehubProxy).owner();
        address ctm = IBridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(gatewayChainId);
        addresses.stateTransition.chainTypeManagerProxy = ctm;
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        require(
            ctmProtocolVersion == config.contracts.latestProtocolVersion,
            "The latest protocol version is not correct"
        );
        serverNotifier = ChainTypeManager(ctm).serverNotifierAddress();
        addresses.bridges.l1AssetRouterProxy = Bridgehub(addresses.bridgehub.bridgehubProxy).assetRouter();

        addresses.vaults.l1NativeTokenVaultProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).nativeTokenVault()
        );
        addresses.bridges.l1NullifierProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).L1_NULLIFIER()
        );

        addresses.bridgehub.ctmDeploymentTrackerProxy = address(
            Bridgehub(addresses.bridgehub.bridgehubProxy).l1CtmDeployer()
        );

        addresses.bridgehub.messageRootProxy = address(Bridgehub(addresses.bridgehub.bridgehubProxy).messageRoot());

        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );
        // It is used as the ecosystem admin inside the `DeployL1` contract
        addresses.chainAdmin = Bridgehub(addresses.bridgehub.bridgehubProxy).admin();
    }

    function deployGatewayCTM() internal {
        (DeployedContracts memory expectedGatewayContracts, bytes memory create2Calldata, ) = GatewayCTMDeployerHelper
            .calculateAddresses(bytes32(0), gatewayCTMDeployerConfig);

        bytes[] memory deps = GatewayCTMDeployerHelper.getListOfFactoryDeps();

        for (uint i = 0; i < deps.length; i++) {
            bytes[] memory localDeps = new bytes[](1);
            localDeps[0] = deps[i];
            Utils.runL1L2Transaction({
                l2Calldata: hex"",
                l2GasLimit: 72_000_000,
                l2Value: 0,
                factoryDeps: localDeps,
                dstAddress: address(0),
                chainId: gatewayChainId,
                bridgehubAddress: addresses.bridgehub.bridgehubProxy,
                l1SharedBridgeProxy: addresses.bridges.l1AssetRouterProxy,
                refundRecipient: msg.sender
            });
        }

        Utils.runL1L2Transaction({
            l2Calldata: create2Calldata,
            l2GasLimit: 72_000_000,
            l2Value: 0,
            factoryDeps: new bytes[](0),
            dstAddress: L2_CREATE2_FACTORY_ADDRESS,
            chainId: gatewayChainId,
            bridgehubAddress: addresses.bridgehub.bridgehubProxy,
            l1SharedBridgeProxy: addresses.bridges.l1AssetRouterProxy,
            refundRecipient: msg.sender
        });

        _saveExpectedGatewayContractsToOutput(expectedGatewayContracts);
    }

    function _saveExpectedGatewayContractsToOutput(DeployedContracts memory expectedGatewayContracts) internal {
        output = GatewayCTMOutput({
            gatewayStateTransition: StateTransitionDeployedAddresses({
                chainTypeManagerProxy: expectedGatewayContracts.stateTransition.chainTypeManagerProxy,
                chainTypeManagerProxyAdmin: expectedGatewayContracts.stateTransition.chainTypeManagerProxyAdmin,
                chainTypeManagerImplementation: expectedGatewayContracts.stateTransition.chainTypeManagerImplementation,
                verifier: expectedGatewayContracts.stateTransition.verifier,
                verifierFflonk: expectedGatewayContracts.stateTransition.verifierFflonk,
                verifierPlonk: expectedGatewayContracts.stateTransition.verifierPlonk,
                adminFacet: expectedGatewayContracts.stateTransition.adminFacet,
                mailboxFacet: expectedGatewayContracts.stateTransition.mailboxFacet,
                executorFacet: expectedGatewayContracts.stateTransition.executorFacet,
                gettersFacet: expectedGatewayContracts.stateTransition.gettersFacet,
                diamondInit: expectedGatewayContracts.stateTransition.diamondInit,
                genesisUpgrade: expectedGatewayContracts.stateTransition.genesisUpgrade,
                validatorTimelock: expectedGatewayContracts.stateTransition.validatorTimelock,
                serverNotifierProxy: expectedGatewayContracts.stateTransition.serverNotifierProxy,
                serverNotifierImplementation: expectedGatewayContracts.stateTransition.serverNotifierImplementation,
                rollupDAManager: expectedGatewayContracts.daContracts.rollupDAManager,
                rollupSLDAValidator: expectedGatewayContracts.daContracts.relayedSLDAValidator,
                // No need for default upgrade on gateway
                defaultUpgrade: address(0),
                diamondProxy: address(0),
                bytecodesSupplier: address(0),
                isOnGateway: true
            }),
            multicall3: expectedGatewayContracts.multicall3,
            diamondCutData: expectedGatewayContracts.diamondCutData,
            relayedSLDAValidator: expectedGatewayContracts.daContracts.relayedSLDAValidator,
            validiumDAValidator: expectedGatewayContracts.daContracts.validiumDAValidator,
            rollupDAManager: expectedGatewayContracts.daContracts.rollupDAManager
        });
    }

    function run() public override {
        console.log("Setting up the Gateway script");

        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("GATEWAY_VOTE_PREPARATION_INPUT"));

        initializeConfig(configPath);
        _initializeGatewayGovernanceConfig(
            GatewayGovernanceConfig({
                bridgehubProxy: addresses.bridgehub.bridgehubProxy,
                l1AssetRouterProxy: addresses.bridges.l1AssetRouterProxy,
                chainTypeManagerProxy: addresses.stateTransition.chainTypeManagerProxy,
                ctmDeploymentTrackerProxy: addresses.bridgehub.ctmDeploymentTrackerProxy,
                gatewayChainId: gatewayChainId
            })
        );
        instantiateCreate2Factory();

        Call[] memory ecosystemAdminCalls;
        if (serverNotifier == address(0)) {
            (, serverNotifier) = deployServerNotifier();

            vm.startBroadcast();
            ServerNotifier(serverNotifier).setChainTypeManager(
                IChainTypeManager(addresses.stateTransition.chainTypeManagerProxy)
            );
            ServerNotifier(serverNotifier).transferOwnership(addresses.chainAdmin);
            vm.stopBroadcast();

            ecosystemAdminCalls = new Call[](2);
            ecosystemAdminCalls[0] = Call({
                target: addresses.stateTransition.chainTypeManagerProxy,
                value: 0,
                data: abi.encodeCall(ChainTypeManager.setServerNotifier, (serverNotifier))
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
            EXPECTED_MAX_L1_GAS_PRICE,
            output.gatewayStateTransition.chainTypeManagerProxy,
            output.rollupDAManager,
            output.gatewayStateTransition.validatorTimelock,
            output.gatewayStateTransition.serverNotifierProxy,
            refundRecipient
        );

        // We need to also whitelist the old L2 rollup address
        if (oldRollupL2DAValidator != address(0)) {
            governanceCalls = Utils.mergeCalls(
                governanceCalls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    EXPECTED_MAX_L1_GAS_PRICE,
                    abi.encodeCall(
                        RollupDAManager.updateDAPair,
                        (output.relayedSLDAValidator, oldRollupL2DAValidator, true)
                    ),
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    output.rollupDAManager,
                    gatewayChainId,
                    addresses.bridgehub.bridgehubProxy,
                    addresses.bridges.l1AssetRouterProxy,
                    refundRecipient
                )
            );
        }

        saveOutput(governanceCalls, ecosystemAdminCalls);
    }

    function saveOutput(Call[] memory governanceCallsToExecute, Call[] memory ecosystemAdminCallsToExecute) internal {
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_proxy_addr",
            output.gatewayStateTransition.chainTypeManagerProxy
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "chain_type_manager_implementation_addr",
            output.gatewayStateTransition.chainTypeManagerImplementation
        );
        vm.serializeAddress("gateway_state_transition", "verifier_addr", output.gatewayStateTransition.verifier);
        vm.serializeAddress("gateway_state_transition", "admin_facet_addr", output.gatewayStateTransition.adminFacet);
        vm.serializeAddress(
            "gateway_state_transition",
            "mailbox_facet_addr",
            output.gatewayStateTransition.mailboxFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "executor_facet_addr",
            output.gatewayStateTransition.executorFacet
        );
        vm.serializeAddress(
            "gateway_state_transition",
            "getters_facet_addr",
            output.gatewayStateTransition.gettersFacet
        );
        vm.serializeAddress("gateway_state_transition", "diamond_init_addr", output.gatewayStateTransition.diamondInit);
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
            output.gatewayStateTransition.validatorTimelock
        );
        string memory gatewayStateTransition = vm.serializeAddress(
            "gateway_state_transition",
            "diamond_proxy_addr",
            output.gatewayStateTransition.diamondProxy
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
