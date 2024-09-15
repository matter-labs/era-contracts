// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnSTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {StateTransitionDeployedAddresses, Utils, L2ContractsBytecodes, L2_BRIDGEHUB_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import { AdminFacet } from "contracts/state-transition/chain-deps/facets/Admin.sol";
import { ExecutorFacet } from "contracts/state-transition/chain-deps/facets/Executor.sol";
import { GettersFacet } from "contracts/state-transition/chain-deps/facets/Getters.sol";
import { Mailbox } from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";

import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";

struct VerifierConfig {
}

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewaySTM is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    address deployerAddress;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehub;
        address stmDeploymentTracker;
        address nativeTokenVault;
        address stateTransitionProxy;
        address sharedBridgeProxy;
        address governance;
        uint256 chainChainId;
        uint256 eraChainId;
        uint256 l1ChainId;
        bool testnetVerifier;

        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
        uint256 diamondInitPubdataPricingMode;
        uint256 diamondInitBatchOverheadL1Gas;
        uint256 diamondInitMaxPubdataPerBatch;
        uint256 diamondInitMaxL2GasPerBatch;
        uint256 diamondInitPriorityTxMaxPubdata;
        uint256 diamondInitMinimalL2GasPrice;

        bytes32 bootloaderHash;
        bytes32 defaultAAHash;

        uint256 priorityTxMaxGasLimit;

        uint256 genesisRollupLeafIndex;
        bytes32 genesisBatchCommitment;

        bytes forceDeploymentsData;
    }

    struct Output {
        StateTransitionDeployedAddresses gatewayStateTransition;
        bytes diamondCutData;
    }

    struct GatewayFacets {
        address adminFacet;
        address mailboxFacet;
        address executorFacet;
        address gettersFacet;
    }

    Config internal config;
    StateTransitionDeployedAddresses internal output;

    function run() public {
        console.log("Setting up the Gateway script");

        initializeConfig();
    }

    function initializeConfig() internal {
        deployerAddress = msg.sender;
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/gateway-deploy.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Initializing all values at once is preferrable to ensure type safety of
        // the fact that all values are initialized
        config = Config({
            bridgehub: toml.readAddress("$.bridgehub_proxy_addr"),
            stmDeploymentTracker: toml.readAddress(
                "$.stm_deployment_tracker_proxy_addr"
            ),
            nativeTokenVault: toml.readAddress("$.native_token_vault_addr"),
            stateTransitionProxy: toml.readAddress(
                "$.state_transition_proxy_addr"
            );
            sharedBridgeProxy: toml.readAddress("$.shared_bridge_proxy_addr"),
            chainChainId: toml.readAddress("$.chain_chain_id"),
            governance: toml.readAddress("$.governance"),
            l1ChainId: toml.readAddress("$.l1_chain_id"),
            eraChainId: toml.readAddress("$.era_chain_id"),
            testnetVerifier: toml.readBool("$.testnet_verifier"),

            recursionNodeLevelVkHash: toml.readBytes32("$.recursion_node_level_vk_hash"),
            recursionLeafLevelVkHash: toml.readBytes32("$.recursion_leaf_level_vk_hash"),
            recursionCircuitsSetVksHash: toml.readBytes32("$.recursion_circuits_set_vks_hash"),
            diamondInitPubdataPricingMode: toml.readUint("$.diamond_init_pubdata_pricing_mode"),
            diamondInitBatchOverheadL1Gas: toml.readUint("$.diamond_init_batch_overhead_l1_gas"),
            diamondInitMaxPubdataPerBatch: toml.readUint("$.diamond_init_max_pubdata_per_batch"),
            diamondInitMaxL2GasPerBatch: toml.readUint("$.diamond_init_max_l2_gas_per_batch"),
            diamondInitPriorityTxMaxPubdata: toml.readUint("$.diamond_init_priority_tx_max_pubdata"),

            diamondInitMinimalL2GasPrice: toml.readUint("$.diamond_init_minimal_l2_gas_price"),
            bootloaderHash: toml.readBytes32("$.bootloader_hash"),
            defaultAAHash: toml.readBytes32("$.default_aa_hash"),
            priorityTxMaxGasLimit: toml.readUint("$.priority_tx_max_gas_limit"),
            genesisRollupLeafIndex: toml.readUint("$.genesis_rollup_leaf_index"),
            genesisBatchCommitment: toml.readBytes32("$.genesis_batch_commitment"),
            forceDeploymentsData: toml.readBytes("$.force_deployments_data")
        });
    
    }

    function saveOutput() internal {
        vm.serializeAddress(
            "root",
            "state_transition_proxy_addr",
            output.gatewayStateTransition.stateTransitionProxy
        );
        vm.serializeAddress(
            "root",
            "state_transition_implementation_addr",
            output.gatewayStateTransition.stateTransitionImplementation
        );
        vm.serializeAddress("root", "verifier_addr", output.gatewayStateTransition.verifier);
        vm.serializeAddress("root", "admin_facet_addr", output.gatewayStateTransition.adminFacet);
        vm.serializeAddress("root", "mailbox_facet_addr", output.gatewayStateTransition.mailboxFacet);
        vm.serializeAddress("root", "executor_facet_addr", output.gatewayStateTransition.executorFacet);
        vm.serializeAddress("root", "getters_facet_addr", output.gatewayStateTransition.gettersFacet);
        vm.serializeAddress("root", "diamond_init_addr", output.gatewayStateTransition.diamondInit);
        vm.serializeAddress("root", "genesis_upgrade_addr", output.gatewayStateTransition.genesisUpgrade);
        vm.serializeAddress("root", "default_upgrade_addr", output.gatewayStateTransition.defaultUpgrade);
        vm.serializeAddress(
            "root",
            "diamond_proxy_addr",
            output.gatewayStateTransition.diamondProxy
        );
        string memory toml = vm.serializeAddress("root", "diamond_cut_data", output.diamondCutData);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-gateway-deploy.toml");
        vm.writeToml(toml, path);
    }

    /// @dev The sender may not have any privileges
    function deployGatewayContracts() public {
        L2ContractsBytecodes memory bytecodes = Utils.readL2ContractsBytecodes();

        
        deployGatewayFacets(bytecodes);

        output.gatewayStateTransition.verifier = deployGatewayVerifier(bytecodes);
        output.gatewayStateTransition.validatorTimelock = deployValidatorTimelock(bytecodes);
        output.gatewayStateTransition.genesisUpgrade = address(new L1GenesisUpgrade());
        console.log("Genesis upgrade deployed at", output.gatewayStateTransition.genesisUpgrade);
        output.gatewayStateTransition.defaultUpgrade = address(new DefaultUpgrade());
        console.log("Default upgrade deployed at", output.gatewayStateTransition.defaultUpgrade);
        output.gatewayStateTransition.diamondInit = address(new DiamondInit());
        console.log("Diamond init deployed at", output.gatewayStateTransition.diamondInit);

        deployGatewayStateTransitionManager();
        setStateTransitionManagerInValidatorTimelock();
    }

    function _deployInternal(bytes memory bytecode, bytes memory constructorargs) internal returns (address) {
        return Utils.deployThroughL1({
            bytecode: bytecode,
            constructorargs: constructorargs,
            create2salt: bytes32(0),
            l2GasLimit Utils.MAX_PRIORITY_TX_GAS,
            new bytes()[0],
            config.chainChainId,
            config.bridgehub,
            address l1SharedBridgeProxy
        })
    }

    function deployGatewayFacets(L2ContractsBytecodes memory bytecodes) internal returns (GatewayFacets memory facets) {
        address adminFacet = address(
            _deployInternal(bytecodes.adminFacet, abi.encode(config.l1ChainId))
        );
        console.log("Admin facet deployed at", adminFacet);

        address mailboxFacet = address(_deployInternal(bytecodes.mailboxFacet, abi.encode(config.l1ChainId, config.eraChainId)));
        console.log("Mailbox facet deployed at", mailboxFacet);
        
        address executorFacet = address(_deployInternal(bytecodes.executorFacet, hex""));
        console.log("ExecutorFacet facet deployed at", executorFacet);
        
        address gettersFacet = address(_deployInternal(bytecodes.gettersFacet, hex""));
        console.log("Getters facet deployed at", gettersFacet);

        output.gatewayStateTransition.adminFacet = adminFacet;
        output.gatewayStateTransition.mailboxFacet = mailboxFacet;
        output.gatewayStateTransition.executorFacet = executorFacet;
        output.gatewayStateTransition.gettersFacet = gettersFacet;
        

        // FIXME: maybe remove the returned value
        facets = GatewayFacets({
            adminFacet: adminFacet,
            mailboxFacet: mailboxFacet,
            executorFacet: executorFacet,
            gettersFacet: gettersFacet
        });
    }

    function deployGatewayVerifier(L2ContractsBytecodes memory bytecodes) internal returns (address verifier) {
        if (config.testnetVerifier) {
            verifier = address(_deployInternal(bytecodes.testnetVerifier, hex""));
        } else {
            verifier = address(_deployInternal(bytecodes.verifier, hex""));
        }

        console.log("Verifier deployed at", verifier);
    }

    function deployValidatorTimelock(L2ContractsBytecodes memory bytecodes) internal returns (address validatorTimelock) {
        // address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        // FIXME: eventually the governance should be moved to the governance contract
        validatorTimelock = address(_deployInternal(bytecodes.validatorTimelock, abi.encode(deployerAddress, 0, config.eraChainId)));
        console.log("Validator timelock deployed at", validatorTimelock);
    }

    function deployGatewayStateTransitionManager() internal {
        // We need to publish the bytecode of the diamdon proxy contract,
        // we can only do it via deploying its dummy version.
        // FIXME: this was straightworward copy pasted from another code where there was not factory deps publishing
        address dp = address(_deployInternal(bytecodes.diamondProxy, hex""));
        console.log("Dummy diamond proxy deployed at", dp);

        output.gatewayStateTransition.stateTransitionImplementation = address(_deployInternal(bytecodes.stateTransitionManager, abi.encode(L2_BRIDGEHUB_ADDRESS)));
        console.log("StateTransitionImplementation deployed at", output.gatewayStateTransition.stateTransitionImplementation);

        // FIXME: eventually a proxy admin or something should be deplyoed here
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: output.gatewayStateTransition.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectorsForFacet("Admin")
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: output.gatewayStateTransition.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectorsForFacet("Getters")
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: output.gatewayStateTransition.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectorsForFacet("Mailbox")
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: output.gatewayStateTransition.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectorsForFacet("Executor")
        });

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.recursionCircuitsSetVksHash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: config.diamondInitPubdataPricingMode,
            batchOverheadL1Gas: uint32(config.diamondInitBatchOverheadL1Gas),
            maxPubdataPerBatch: uint32(config.diamondInitMaxPubdataPerBatch),
            maxL2GasPerBatch: uint32(config.diamondInitMaxL2GasPerBatch),
            priorityTxMaxPubdata: uint32(config.diamondInitPriorityTxMaxPubdata),
            minimalL2GasPrice: uint64(config.diamondInitMinimalL2GasPrice)
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(output.gatewayStateTransition.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: config.bootloaderHash,
            l2DefaultAccountBytecodeHash: config.defaultAAHash,
            priorityTxMaxGasLimit: config.priorityTxMaxGasLimit,
            feeParams: feeParams,
            // We can not provide zero value there. At the same time, there is no such contract on gateway
            blobVersionedHashRetriever: ADDRESS_ONE
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: output.gatewayStateTransition.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        output.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: output.gatewayStateTransition.genesisUpgrade,
            genesisBatchHash: output.gatewayStateTransition.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(config.genesisRollupLeafIndex),
            genesisBatchCommitment: config.genesisBatchCommitment,
            diamondCut: diamondCut,
            // Note, it is the same as for contracts that are based on L2
            forceDeploymentsData: config.forceDeploymentsData
        });

        StateTransitionManagerInitializeData memory diamondInitData = StateTransitionManagerInitializeData({
            owner: msg.sender,
            validatorTimelock: addresses.validatorTimelock,
            chainCreationParams: chainCreationParams,
            protocolVersion: config.contracts.latestProtocolVersion
        });

        output.gatewayStateTransition.stateTransitionProxy = _deployInternal(bytecodes.transparentUpgradeableProxy, abi.encode(stmImpl, deployerAddress, abi.encodeCall(StateTransitionManager.initialize, (diamondInitData))));

        console.log("StateTransitionManagerProxy deployed at:", output.gatewayStateTransition.stateTransitionProxy);
        output.gatewayStateTransition.stateTransitionProxy = output.gatewayStateTransition.stateTransitionProxy;
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(output.gatewayStateTransition.validatorTimelock);
        vm.broadcast();
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(output.gatewayStateTransition.stateTransitionProxy)
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
    }

}
