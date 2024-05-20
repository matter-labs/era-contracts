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

contract RegisterHyperchainsScript is Script {
    using stdToml for string;

    address[] diamondProxyAddresses;
    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    struct HyperchainsConfig {
        HyperchainDescription[] hyperchains;
    }

    struct HyperchainDescription {
        uint256 hyperchainChainId;
        address baseToken;
        uint256 bridgehubCreateNewChainSalt;
        bool validiumMode;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
    }

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

    Config config;
    HyperchainsConfig hyperchainsConfig;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();
        checkTokenAddresses();
        registerTokensOnBridgehub();
        registerHyperchains();
        addValidators();
        configureZkSyncStateTransitions();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/scripts-rs/script-out/output-deploy-l1.toml");
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

        // get hyperchains config
        root = vm.projectRoot();
        path = string.concat(root, "/scripts-rs/script-config/config-deploy-hyperchains.toml");
        toml = vm.readFile(path);

        string[] memory hyperchains = vm.parseTomlKeys(toml, "$.hyperchains");

        for (uint256 i = 0; i < hyperchains.length; i++) {
            HyperchainDescription memory hyperchain;
            string memory key = string.concat("$.hyperchains.", hyperchains[i]);

            hyperchain.hyperchainChainId = toml.readUint(string.concat(key, ".hyperchain_chain_id"));
            hyperchain.baseToken = toml.readAddress(string.concat(key, ".base_token_addr "));
            hyperchain.bridgehubCreateNewChainSalt = toml.readUint(
                string.concat(key, ".bridgehub_create_new_chain_salt")
            );
            hyperchain.validiumMode = toml.readBool(string.concat(key, ".validium_mode"));
            hyperchain.validatorSenderOperatorCommitEth = toml.readAddress(
                string.concat(key, ".validator_sender_operator_commit_eth")
            );
            hyperchain.validatorSenderOperatorBlobsEth = toml.readAddress(
                string.concat(key, ".validator_sender_operator_blobs_eth")
            );
            hyperchain.baseTokenGasPriceMultiplierNominator = uint128(
                toml.readUint(string.concat(key, ".base_token_gas_price_multiplier_nominator"))
            );
            hyperchain.baseTokenGasPriceMultiplierDenominator = uint128(
                toml.readUint(string.concat(key, ".base_token_gas_price_multiplier_denominator"))
            );

            hyperchainsConfig.hyperchains.push(hyperchain);
        }
    }

    function checkTokenAddresses() internal {
        for (uint256 i = 0; i < hyperchainsConfig.hyperchains.length; i++) {
            address baseToken = hyperchainsConfig.hyperchains[i].baseToken;

            if (baseToken == address(0)) {
                revert("Token address is not set");
            }

            // Check if it's ethereum address
            if (baseToken == ADDRESS_ONE) {
                return;
            }

            if (baseToken.code.length == 0) {
                revert("Token address is not a contract address");
            }
        }
    }

    function registerTokensOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.addresses.bridgehub);
        for (uint256 i = 0; i < hyperchainsConfig.hyperchains.length; i++) {
            address baseToken = hyperchainsConfig.hyperchains[i].baseToken;

            if (bridgehub.tokenIsRegistered(baseToken)) {
                console.log("Token already registered on Bridgehub");
            } else {
                vm.broadcast();
                bridgehub.addToken(baseToken);
                console.log("Token registered on Bridgehub");
            }
        }
    }

    function registerHyperchains() internal {
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

        for (uint256 i = 0; i < hyperchainsConfig.hyperchains.length; i++) {
            HyperchainDescription description = hyperchainsConfig.hyperchains[i];

            bridgehub.createNewChain({
                _chainId: description.hyperchainChainId,
                _stateTransitionManager: config.addresses.stateTransitionProxy,
                _baseToken: description.baseToken,
                _salt: description.bridgehubCreateNewChainSalt,
                _admin: msg.sender,
                _initData: abi.encode(initData)
            });
            console.log("Hyperchain registered");
        }

        // Get new diamond proxy address from emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == STATE_TRANSITION_NEW_CHAIN_HASH) {
                diamondProxyAddresses.push(address(uint160(uint256(logs[i].topics[2]))));

                found++;

                if (found == hyperchainsConfig.hyperchains.length) {
                    break;
                }
            }
        }

        for (uint256 i = 0; i < diamondProxyAddresses.length; i++) {
            address newProxyAddress = diamondProxyAddresses[i];

            if (diamondProxyAddress == address(0)) {
                revert("One of diamond proxy addresses not found");
            }
        }
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.addresses.validatorTimelock);

        vm.startBroadcast();

        for (uint256 i = 0; i < hyperchainsConfig.hyperchains.length; i++) {
            HyperchainDescription description = hyperchainsConfig.hyperchains[i];
            validatorTimelock.addValidator(description.hyperchainChainId, description.validatorSenderOperatorCommitEth);
            validatorTimelock.addValidator(description.hyperchainChainId, description.validatorSenderOperatorBlobsEth);
        }

        vm.stopBroadcast();

        console.log("Validators added");
    }

    function configureZkSyncStatesTransition() internal {
        vm.startBroadcast();

        for (uint256 i = 0; i < diamondProxyAddresses.length; i++) {
            IZkSyncHyperchain zkSyncStateTransition = IZkSyncHyperchain(diamondProxyAddresses[i]);
            HyperchainDescription description = hyperchainsConfig.hyperchains[i];

            zkSyncStateTransition.setTokenMultiplier(
                description.baseTokenGasPriceMultiplierNominator,
                description.baseTokenGasPriceMultiplierDenominator
            );

            // TODO: support validium mode when available
            // if (config.contractsMode) {
            //     zkSyncStateTransition.setValidiumMode(PubdataPricingMode.Validium);
            // }
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }
}
