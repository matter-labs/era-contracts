// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

contract DeployL1Script is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;

    struct Config {
        ContractsConfig contracts;
        AddressesConfig addresses;
        address deployerAddress;
        uint256 eraChainId;
    }

    struct ContractsConfig {
        uint256 bridgehubCreateNewChainSalt;
        uint256 diamondInitBatchOverheadL1Gas;
        uint256 diamondInitMaxPubdataPerBatch;
        uint256 diamondInitMaxL2GasPerBatch;
        uint256 diamondInitPriorityTxMaxPubdata;
        uint256 diamondInitMinimalL2GasPrice;
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
        uint256 priorityTxMaxGasLimit;
    }

    struct AddressesConfig {
        address baseToken;
        address bridgehub;
        address stateTransitionProxy;
        address adminFacet;
        address gettersFacet;
        address mailboxFacet;
        address executorFacet;
        address verifier;
        address blobVersionedHashRetriever;
        address diamondInit;
    }

    Config config;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-hyperchain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.addresses.baseToken = toml.readAddress("$.addresses.base_token");
        config.addresses.bridgehub = toml.readAddress("$.addresses.bridgehub");
        config.addresses.stateTransitionProxy = toml.readAddress("$.addresses.state_transition_proxy");
        config.addresses.adminFacet = toml.readAddress("$.addresses.admin_facet");
        config.addresses.gettersFacet = toml.readAddress("$.addresses.getters_facet");
        config.addresses.mailboxFacet = toml.readAddress("$.addresses.mailbox_facet");
        config.addresses.executorFacet = toml.readAddress("$.addresses.executor_facet");
        config.addresses.verifier = toml.readAddress("$.addresses.verifier");
        config.addresses.blobVersionedHashRetriever = toml.readAddress("$.addresses.blob_versioned_hash_retriever");
        config.addresses.diamondInit = toml.readAddress("$.addresses.diamond_init");

        config.contracts.bridgehubCreateNewChainSalt = toml.readUint("$.contracts.bridgehub_create_new_chain_salt");
        config.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.contracts.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.contracts.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.contracts.diamond_init_max_l2_gas_per_batch");
        config.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.contracts.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.contracts.diamond_init_minimal_l2_gas_price");
        config.contracts.recursionNodeLevelVkHash = toml.readBytes32("$.contracts.recursion_node_level_vk_hash");
        config.contracts.recursionLeafLevelVkHash = toml.readBytes32("$.contracts.recursion_leaf_level_vk_hash");
        config.contracts.recursionCircuitsSetVksHash = toml.readBytes32("$.contracts.recursion_circuits_set_vks_hash");
        config.contracts.priorityTxMaxGasLimit = toml.readUint("$.contracts.priority_tx_max_gas_limit");
    }

    function checkTokenAddress() internal {
        if (config.addresses.baseToken == address(0)) {
            revert("Token address is not set");
        }

        // Check if it's ethereum address
        if (config.addresses.baseToken == ADDRESS_ONE) {
            return;
        }

        if (config.addresses.baseToken.code.length == 0) {
            revert("Token address is not set");
        }

        console.log("Using base token address:", config.addresses.baseToken);
    }

    function registerTokenOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.addresses.bridgehub);

        if (bridgehub.tokenIsRegistered(config.addresses.baseToken)) {
            console.log("Token already registered on Bridgehub");
        } else {
            vm.broadcast();
            bridgehub.addToken(config.addresses.baseToken);
            console.log("Token registered on Bridgehub");
        }
    }

    function registerHyperchain() internal {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: config.addresses.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(config.addresses.adminFacet.code)
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: config.addresses.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(config.addresses.gettersFacet.code)
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: config.addresses.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(config.addresses.mailboxFacet.code)
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: config.addresses.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(config.addresses.executorFacet.code)
        });

        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: config.contracts.recursionNodeLevelVkHash,
            recursionLeafLevelVkHash: config.contracts.recursionLeafLevelVkHash,
            recursionCircuitsSetVksHash: config.contracts.recursionCircuitsSetVksHash
        });

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: uint32(config.contracts.diamondInitBatchOverheadL1Gas),
            maxPubdataPerBatch: uint32(config.contracts.diamondInitMaxPubdataPerBatch),
            maxL2GasPerBatch: uint32(config.contracts.diamondInitMaxL2GasPerBatch),
            priorityTxMaxPubdata: uint32(config.contracts.diamondInitPriorityTxMaxPubdata),
            minimalL2GasPrice: uint64(config.contracts.diamondInitMinimalL2GasPrice)
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(config.addresses.verifier),
            verifierParams: verifierParams,
            l2BootloaderBytecodeHash: bytes32(Utils.getBatchBootloaderBytecodeHash()),
            l2DefaultAccountBytecodeHash: bytes32(Utils.readSystemContractsBytecode("DefaultAccount")),
            priorityTxMaxGasLimit: config.contracts.priorityTxMaxGasLimit,
            feeParams: feeParams,
            blobVersionedHashRetriever: config.addresses.blobVersionedHashRetriever
        });

        Diamond.DiamondCutData memory initData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: config.addresses.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        IBridgehub bridgehub = IBridgehub(config.addresses.bridgehub);

        vm.broadcast();
        bridgehub.createNewChain(
            config.eraChainId,
            config.addresses.stateTransitionProxy,
            config.addresses.baseToken,
            config.contracts.bridgehubCreateNewChainSalt,
            msg.sender,
            abi.encode(initData)
        );
    }
}
