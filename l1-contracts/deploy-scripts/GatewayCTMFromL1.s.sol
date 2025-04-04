// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_CREATE2_FACTORY_ADDRESS, ADDRESS_ONE} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";

import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerHelper} from "./GatewayCTMDeployerHelper.sol";

import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";


/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayCTMFromL1 is Script {
    using stdToml for string;

    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehub;
        address ctmDeploymentTracker;
        address nativeTokenVault;
        address chainTypeManagerProxy;
        address sharedBridgeProxy;
        address governanceAddr;
        address baseToken;
        uint256 chainChainId;
        uint256 eraChainId;
        uint256 l1ChainId;
        bool testnetVerifier;
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
        PubdataPricingMode diamondInitPubdataPricingMode;
        uint256 diamondInitBatchOverheadL1Gas;
        uint256 diamondInitMaxPubdataPerBatch;
        uint256 diamondInitMaxL2GasPerBatch;
        uint256 diamondInitPriorityTxMaxPubdata;
        uint256 diamondInitMinimalL2GasPrice;
        bytes32 bootloaderHash;
        bytes32 defaultAAHash;
        bytes32 evmEmulatorHash;
        uint256 priorityTxMaxGasLimit;
        bytes32 genesisRoot;
        uint256 genesisRollupLeafIndex;
        bytes32 genesisBatchCommitment;
        uint256 latestProtocolVersion;
        address expectedRollupL2DAValidator; 
        bytes forceDeploymentsData;
    }

    struct Output {
        StateTransitionDeployedAddresses gatewayStateTransition;
        address multicall3;
        bytes diamondCutData;
        address relayedSLDAValidator;
        address validiumDAValidator;
        address whitelistedBytecodesFactory;
        address rollupDAManager;
    }

    Config internal config;
    GatewayCTMDeployerConfig internal gatewayCTMDeployerConfig;
    Output internal output;

    function getOutput() external returns (Output memory) {
        return output;
    }

    function prepareAddresses() external {
        initializeConfig();
        if (config.baseToken != ADDRESS_ONE) {
            distributeBaseToken();
        }

        (DeployedContracts memory expectedGatewayContracts, bytes memory create2Calldata, ) = GatewayCTMDeployerHelper
            .calculateAddresses(bytes32(0), gatewayCTMDeployerConfig);

        bytes memory whitelistedBytecodesFactory = Utils.readZKFoundryBytecodeL1("WhitelistedBytecodeFactory.sol", "WhitelistedBytecodeFactory");
        _saveExpectedGatewayContractsToOutput(expectedGatewayContracts, Utils.getL2AddressViaCreate2Factory(gatewayCTMDeployerConfig.salt, L2ContractHelper.hashL2Bytecode(whitelistedBytecodesFactory), constructorArgs););
        saveOutput();
    }

    function deployCTM() external {
        initializeConfig();

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
                chainId: config.chainChainId,
                bridgehubAddress: config.bridgehub,
                l1SharedBridgeProxy: config.sharedBridgeProxy
            });
        }

        Utils.runL1L2Transaction({
            l2Calldata: create2Calldata,
            l2GasLimit: 72_000_000,
            l2Value: 0,
            factoryDeps: new bytes[](0),
            dstAddress: L2_CREATE2_FACTORY_ADDRESS,
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        address whitelistedBytecodesFactory = deployWhitelistedBytecodeFactory();

        _saveExpectedGatewayContractsToOutput(expectedGatewayContracts, whitelistedBytecodesFactory);
        saveOutput();
    }

    function deployWhitelistedBytecodeFactory() internal returns (address) {
        return Utils.deployThroughL1Deterministic(
            Utils.readZKFoundryBytecodeL1("WhitelistedBytecodeFactory.sol", "WhitelistedBytecodeFactory"), 
            abi.encode(AddressAliasHelper.applyL1ToL2Alias(_admin)), 
            gatewayCTMDeployerConfig.salt, 
            72_000_000, 
            new bytes[](0), 
            config.chainChainId, 
            config.bridgehub, 
            config.sharedBridgeProxy
        );
    }

    function _saveExpectedGatewayContractsToOutput(DeployedContracts memory expectedGatewayContracts, address _whitelistedBytecodesFactory) internal {
        output = Output({
            gatewayStateTransition: StateTransitionDeployedAddresses({
                chainTypeManagerProxy: expectedGatewayContracts.stateTransition.chainTypeManagerProxy,
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
            rollupDAManager: expectedGatewayContracts.daContracts.rollupDAManager,
            whitelistedBytecodesFactory: _whitelistedBytecodesFactory
        });
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("DEPLOY_GATEWAY_CTM_CONFIG"));
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Initializing all values at once is preferable to ensure type safety of
        // the fact that all values are initialized
        config = Config({
            bridgehub: toml.readAddress("$.bridgehub_proxy_addr"),
            ctmDeploymentTracker: toml.readAddress("$.ctm_deployment_tracker_proxy_addr"),
            nativeTokenVault: toml.readAddress("$.native_token_vault_addr"),
            chainTypeManagerProxy: toml.readAddress("$.chain_type_manager_proxy_addr"),
            sharedBridgeProxy: toml.readAddress("$.shared_bridge_proxy_addr"),
            chainChainId: toml.readUint("$.chain_chain_id"),
            governanceAddr: toml.readAddress("$.governance"),
            baseToken: toml.readAddress("$.base_token"),
            l1ChainId: toml.readUint("$.l1_chain_id"),
            eraChainId: toml.readUint("$.era_chain_id"),
            testnetVerifier: toml.readBool("$.testnet_verifier"),
            recursionNodeLevelVkHash: toml.readBytes32("$.recursion_node_level_vk_hash"),
            recursionLeafLevelVkHash: toml.readBytes32("$.recursion_leaf_level_vk_hash"),
            recursionCircuitsSetVksHash: toml.readBytes32("$.recursion_circuits_set_vks_hash"),
            diamondInitPubdataPricingMode: PubdataPricingMode(toml.readUint("$.diamond_init_pubdata_pricing_mode")),
            diamondInitBatchOverheadL1Gas: toml.readUint("$.diamond_init_batch_overhead_l1_gas"),
            diamondInitMaxPubdataPerBatch: toml.readUint("$.diamond_init_max_pubdata_per_batch"),
            diamondInitMaxL2GasPerBatch: toml.readUint("$.diamond_init_max_l2_gas_per_batch"),
            diamondInitPriorityTxMaxPubdata: toml.readUint("$.diamond_init_priority_tx_max_pubdata"),
            diamondInitMinimalL2GasPrice: toml.readUint("$.diamond_init_minimal_l2_gas_price"),
            bootloaderHash: toml.readBytes32("$.bootloader_hash"),
            defaultAAHash: toml.readBytes32("$.default_aa_hash"),
            evmEmulatorHash: toml.readBytes32("$.evm_emulator_hash"),
            priorityTxMaxGasLimit: toml.readUint("$.priority_tx_max_gas_limit"),
            genesisRoot: toml.readBytes32("$.genesis_root"),
            genesisRollupLeafIndex: toml.readUint("$.genesis_rollup_leaf_index"),
            genesisBatchCommitment: toml.readBytes32("$.genesis_batch_commitment"),
            latestProtocolVersion: toml.readUint("$.latest_protocol_version"),
            expectedRollupL2DAValidator: toml.readAddress("$.expected_rollup_l2_da_validator"),
            forceDeploymentsData: toml.readBytes("$.force_deployments_data")
        });

        address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.governanceAddr);
        gatewayCTMDeployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: aliasedGovernor,
            salt: bytes32(0),
            eraChainId: config.eraChainId,
            l1ChainId: config.l1ChainId,
            rollupL2DAValidatorAddress: config.expectedRollupL2DAValidator,
            testnetVerifier: config.testnetVerifier,
            adminSelectors: Utils.getAllSelectorsForFacet("Admin"),
            executorSelectors: Utils.getAllSelectorsForFacet("Executor"),
            mailboxSelectors: Utils.getAllSelectorsForFacet("Mailbox"),
            gettersSelectors: Utils.getAllSelectorsForFacet("Getters"),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: config.recursionNodeLevelVkHash,
                recursionLeafLevelVkHash: config.recursionLeafLevelVkHash,
                recursionCircuitsSetVksHash: config.recursionCircuitsSetVksHash
            }),
            feeParams: FeeParams({
                pubdataPricingMode: config.diamondInitPubdataPricingMode,
                batchOverheadL1Gas: uint32(config.diamondInitBatchOverheadL1Gas),
                maxPubdataPerBatch: uint32(config.diamondInitMaxPubdataPerBatch),
                maxL2GasPerBatch: uint32(config.diamondInitMaxL2GasPerBatch),
                priorityTxMaxPubdata: uint32(config.diamondInitPriorityTxMaxPubdata),
                minimalL2GasPrice: uint64(config.diamondInitMinimalL2GasPrice)
            }),
            bootloaderHash: config.bootloaderHash,
            defaultAccountHash: config.defaultAAHash,
            evmEmulatorHash: config.evmEmulatorHash,
            priorityTxMaxGasLimit: config.priorityTxMaxGasLimit,
            genesisRoot: config.genesisRoot,
            genesisRollupLeafIndex: uint64(config.genesisRollupLeafIndex),
            genesisBatchCommitment: config.genesisBatchCommitment,
            forceDeploymentsData: config.forceDeploymentsData,
            protocolVersion: config.latestProtocolVersion
        });
    }

    function distributeBaseToken() internal {
        uint256 amountForDistribution = 100000000000000000000;
        L1AssetRouter l1AR = L1AssetRouter(config.sharedBridgeProxy);
        IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(address(l1AR.nativeTokenVault()));
        bytes32 baseTokenAssetID = nativeTokenVault.assetId(config.baseToken);
        uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(baseTokenAssetID);
        TestnetERC20Token baseToken = TestnetERC20Token(config.baseToken);

        vm.startBroadcast();
        if (baseTokenOriginChainId == block.chainid) {
            baseToken.mint(config.governanceAddr, amountForDistribution);
        } else {
            baseToken.transfer(config.governanceAddr, amountForDistribution);
        }
        vm.stopBroadcast();
    }

    function saveOutput() internal {
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

        string memory toml = vm.serializeBytes("root", "diamond_cut_data", output.diamondCutData);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-deploy-gateway-ctm.toml");
        vm.writeToml(toml, path);
    }
}
