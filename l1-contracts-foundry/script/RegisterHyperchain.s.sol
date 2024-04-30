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

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    struct Config {
        ContractsConfig contracts;
        AddressesConfig addresses;
        address deployerAddress;
        address ownerAddress;
        uint256 hyperchainChainId;
    }

    struct ContractsConfig {
        uint256 bridgehubCreateNewChainSalt;
        bytes diamondCutData;
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

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
        addValidators();
        configureZkSyncStateTransition();

        saveOutput();
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
        config.ownerAddress = toml.readAddress("$.owner_addr");

        config.addresses.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.addresses.stateTransitionProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.addresses.adminFacet = toml.readAddress("$.deployed_addresses.state_transition.admin_facet_addr");
        config.addresses.gettersFacet = toml.readAddress("$.deployed_addresses.state_transition.getters_facet_addr");
        config.addresses.mailboxFacet = toml.readAddress("$.deployed_addresses.state_transition.mailbox_facet_addr");
        config.addresses.executorFacet = toml.readAddress("$.deployed_addresses.state_transition.executor_facet_addr");
        config.addresses.verifier = toml.readAddress("$.deployed_addresses.state_transition.verifier_addr");
        config.addresses.blobVersionedHashRetriever = toml.readAddress(
            "$.deployed_addresses.blob_versioned_hash_retriever_addr"
        );
        config.addresses.diamondInit = toml.readAddress("$.deployed_addresses.state_transition.diamond_init_addr");
        config.addresses.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");

        config.contracts.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");

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
            revert("Token address is not set");
        }

        // Check if it's ethereum address
        if (config.addresses.baseToken == ADDRESS_ONE) {
            return;
        }

        if (config.addresses.baseToken.code.length == 0) {
            revert("Token address is not a contract address");
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
        IBridgehub bridgehub = IBridgehub(config.addresses.bridgehub);

        vm.broadcast();
        vm.recordLogs();
        bridgehub.createNewChain({
            _chainId: config.hyperchainChainId,
            _stateTransitionManager: config.addresses.stateTransitionProxy,
            _baseToken: config.addresses.baseToken,
            _salt: config.contracts.bridgehubCreateNewChainSalt,
            _admin: msg.sender,
            _initData: config.contracts.diamondCutData
        });
        console.log("Hyperchain registered");

        // Get new diamond proxy address from emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address diamondProxyAddress;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == STATE_TRANSITION_NEW_CHAIN_HASH) {
                diamondProxyAddress = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found");
        }
        config.addresses.newDiamondProxy = diamondProxyAddress;
        console.log("Hyperchain diamond proxy deployed at:", diamondProxyAddress);
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

    function saveOutput() internal {
        string memory toml = vm.serializeAddress("root", "diamond_proxy_addr", config.addresses.newDiamondProxy);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-hyperchain.toml");
        vm.writeToml(toml, path);
    }
}
