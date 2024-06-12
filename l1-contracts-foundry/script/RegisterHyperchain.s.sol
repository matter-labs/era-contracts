// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ZksyncContract, MissingAddress, AddressHasNoCode} from "./ZkSyncScriptErrors.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    struct Config {
        ContractsConfig contracts;
        AddressesConfig addresses;
        address deployerAddress;
        address ownerAddress;
        uint256 hyperchainChainId;
    }

    struct ContractsConfig {
        uint256 bridgehubCreateNewChainSalt;
        PubdataPricingMode diamondInitPubdataPricingMode;
        uint256 diamondInitBatchOverheadL1Gas;
        uint256 diamondInitMaxPubdataPerBatch;
        uint256 diamondInitMaxL2GasPerBatch;
        uint256 diamondInitPriorityTxMaxPubdata;
        uint256 diamondInitMinimalL2GasPrice;
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
        uint256 priorityTxMaxGasLimit;
        bool validiumMode;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
    }

    // solhint-disable-next-line gas-struct-packing
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
        address validatorTimelock;
        address newDiamondProxy;
    }

    Config internal config;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
        addValidators();
        configureZkSyncStateTransition();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.l1.owner_addr");

        config.addresses.bridgehub = toml.readAddress("$.l1.bridgehub.bridgehub_proxy_addr");
        config.addresses.stateTransitionProxy = toml.readAddress("$.l1.state_transition.state_transition_proxy_addr");
        config.addresses.adminFacet = toml.readAddress("$.l1.state_transition.admin_facet_addr");
        config.addresses.gettersFacet = toml.readAddress("$.l1.state_transition.getters_facet_addr");
        config.addresses.mailboxFacet = toml.readAddress("$.l1.state_transition.mailbox_facet_addr");
        config.addresses.executorFacet = toml.readAddress("$.l1.state_transition.executor_facet_addr");
        config.addresses.verifier = toml.readAddress("$.l1.state_transition.verifier_addr");
        config.addresses.blobVersionedHashRetriever = toml.readAddress("$.l1.blob_versioned_hash_retriever_addr");
        config.addresses.diamondInit = toml.readAddress("$.l1.state_transition.diamond_init_addr");
        config.addresses.validatorTimelock = toml.readAddress("$.l1.validator_timelock_addr");

        config.contracts.diamondInitPubdataPricingMode = PubdataPricingMode(
            toml.readUint("$.l1.config.diamond_init_pubdata_pricing_mode")
        );
        config.contracts.diamondInitBatchOverheadL1Gas = toml.readUint(
            "$.l1.config.diamond_init_batch_overhead_l1_gas"
        );
        config.contracts.diamondInitMaxPubdataPerBatch = toml.readUint(
            "$.l1.config.diamond_init_max_pubdata_per_batch"
        );
        config.contracts.diamondInitMaxL2GasPerBatch = toml.readUint("$.l1.config.diamond_init_max_l2_gas_per_batch");
        config.contracts.diamondInitPriorityTxMaxPubdata = toml.readUint(
            "$.l1.config.diamond_init_priority_tx_max_pubdata"
        );
        config.contracts.diamondInitMinimalL2GasPrice = toml.readUint("$.l1.config.diamond_init_minimal_l2_gas_price");
        config.contracts.recursionNodeLevelVkHash = toml.readBytes32("$.l1.config.recursion_node_level_vk_hash");
        config.contracts.recursionLeafLevelVkHash = toml.readBytes32("$.l1.config.recursion_leaf_level_vk_hash");
        config.contracts.recursionCircuitsSetVksHash = toml.readBytes32("$.l1.config.recursion_circuits_set_vks_hash");
        config.contracts.priorityTxMaxGasLimit = toml.readUint("$.l1.config.priority_tx_max_gas_limit");

        // Grab config from l1 deployment config
        root = vm.projectRoot();
        path = string.concat(root, "/script-config/config-deploy-l1.toml");
        toml = vm.readFile(path);

        config.hyperchainChainId = toml.readUint("$.hyperchain.hyperchain_chain_id");
        config.contracts.bridgehubCreateNewChainSalt = toml.readUint("$.hyperchain.bridgehub_create_new_chain_salt");
        config.addresses.baseToken = toml.readAddress("$.hyperchain.base_token_addr");
        config.contracts.validiumMode = toml.readBool("$.hyperchain.validium_mode");
        config.contracts.validatorSenderOperatorCommitEth = toml.readAddress(
            "$.hyperchain.validator_sender_operator_commit_eth"
        );
        config.contracts.validatorSenderOperatorBlobsEth = toml.readAddress(
            "$.hyperchain.validator_sender_operator_blobs_eth"
        );
        config.contracts.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.hyperchain.base_token_gas_price_multiplier_nominator")
        );
        config.contracts.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.hyperchain.base_token_gas_price_multiplier_denominator")
        );
    }

    function checkTokenAddress() internal {
        if (config.addresses.baseToken == address(0)) {
            revert MissingAddress(ZksyncContract.BaseToken);
        }

        // Check if it's ethereum address
        if (config.addresses.baseToken == ADDRESS_ONE) {
            return;
        }

        if (config.addresses.baseToken.code.length == 0) {
            revert AddressHasNoCode(config.addresses.baseToken);
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
            pubdataPricingMode: config.contracts.diamondInitPubdataPricingMode,
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
        vm.recordLogs();
        bridgehub.createNewChain({
            _chainId: config.hyperchainChainId,
            _stateTransitionManager: config.addresses.stateTransitionProxy,
            _baseToken: config.addresses.baseToken,
            _salt: config.contracts.bridgehubCreateNewChainSalt,
            _admin: msg.sender,
            _initData: abi.encode(initData)
        });
        console.log("Hyperchain registered");

        // Get new diamond proxy address from emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address diamondProxyAddress;
        uint256 logsLength = logs.length;
        for (uint256 i = 0; i < logsLength; ++i) {
            if (logs[i].topics[0] == STATE_TRANSITION_NEW_CHAIN_HASH) {
                diamondProxyAddress = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        if (diamondProxyAddress == address(0)) {
            revert MissingAddress(ZksyncContract.DiamondProxy);
        }
        config.addresses.newDiamondProxy = diamondProxyAddress;
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.addresses.validatorTimelock);

        vm.startBroadcast();
        validatorTimelock.addValidator(config.hyperchainChainId, config.contracts.validatorSenderOperatorCommitEth);
        validatorTimelock.addValidator(config.hyperchainChainId, config.contracts.validatorSenderOperatorBlobsEth);
        vm.stopBroadcast();

        console.log("Validators added");
    }

    function configureZkSyncStateTransition() internal {
        IZkSyncHyperchain zkSyncStateTransition = IZkSyncHyperchain(config.addresses.newDiamondProxy);

        vm.startBroadcast();
        zkSyncStateTransition.setTokenMultiplier(
            config.contracts.baseTokenGasPriceMultiplierNominator,
            config.contracts.baseTokenGasPriceMultiplierDenominator
        );

        // TODO: support validium mode when available
        // if (config.contractsMode) {
        //     zkSyncStateTransition.setValidiumMode(PubdataPricingMode.Validium);
        // }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }
}
