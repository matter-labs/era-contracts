// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";

import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Utils} from "./Utils.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 chainChainId;
        address proposalAuthor;
        address chainRegistrar;
        address bridgehub;
        uint256 bridgehubCreateNewChainSalt;
        address stateTransitionProxy;
        address validatorTimelock;
        bytes diamondCutData;
        address newDiamondProxy;
        address chainAdmin;
    }

    ChainRegistrar internal chainRegistrar;
    Config internal config;
    ChainRegistrar.ChainConfig internal chainConfig;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();
        loadChain();

        deployChainAdmin();
        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        saveOutput();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-hyperchain.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.stateTransitionProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.chainRegistrar = toml.readAddress("$.deployed_addresses.chain_registrar");
        chainRegistrar = ChainRegistrar(config.chainRegistrar);

        config.bridgehub = address(chainRegistrar.bridgehub());
        config.validatorTimelock = StateTransitionManager(config.stateTransitionProxy).validatorTimelock();
        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");

        config.chainChainId = toml.readUint("$.chain.chain_chain_id");
        config.proposalAuthor = toml.readAddress("$.chain.proposal_author");
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
    }

    function loadChain() internal {
        chainConfig = chainRegistrar.getChainConfig(config.proposalAuthor, config.chainChainId);
    }

    function checkTokenAddress() internal view {
        if (chainConfig.baseToken.tokenAddress == address(0)) {
            revert("Token address is not set");
        }

        // Check if it's ethereum address
        if (chainConfig.baseToken.tokenAddress == ADDRESS_ONE) {
            return;
        }

        if (chainConfig.baseToken.tokenAddress.code.length == 0) {
            revert("Token address is not a contract address");
        }

        console.log("Using base token address:", chainConfig.baseToken.tokenAddress);
    }

    function registerTokenOnBridgehub() internal {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        if (bridgehub.tokenIsRegistered(chainConfig.baseToken.tokenAddress)) {
            console.log("Token already registered on Bridgehub");
        } else {
            bytes memory data = abi.encodeCall(bridgehub.addToken, (chainConfig.baseToken.tokenAddress));
            Utils.chainAdminMulticall({
                _chainAdmin: bridgehub.admin(),
                _target: config.bridgehub,
                _data: data,
                _value: 0
            });
            console.log("Token registered on Bridgehub");
        }
    }

    function deployChainAdmin() internal {
        vm.broadcast();
        ChainAdmin chainAdmin = new ChainAdmin(chainConfig.governor, chainConfig.baseToken.tokenMultiplierSetter);
        console.log("ChainAdmin deployed at:", address(chainAdmin));
        config.chainAdmin = address(chainAdmin);
    }

    function registerHyperchain() internal {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        vm.recordLogs();
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                chainConfig.chainId,
                config.stateTransitionProxy,
                chainConfig.baseToken.tokenAddress,
                config.bridgehubCreateNewChainSalt,
                msg.sender,
                config.diamondCutData
            )
        );

        Utils.chainAdminMulticall({_chainAdmin: bridgehub.admin(), _target: config.bridgehub, _data: data, _value: 0});
        console.log("Hyperchain registered");

        // Get new diamond proxy address from bridgehub
        address diamondProxyAddress = bridgehub.getHyperchain(chainConfig.chainId);
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found");
        }
        config.newDiamondProxy = diamondProxyAddress;
        console.log("Hyperchain diamond proxy deployed at:", diamondProxyAddress);
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);

        vm.startBroadcast();
        validatorTimelock.addValidator(chainConfig.chainId, chainConfig.blobOperator);
        validatorTimelock.addValidator(chainConfig.chainId, chainConfig.operator);
        vm.stopBroadcast();

        console.log("Validators added");
    }

    function configureZkSyncStateTransition() internal {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);

        vm.startBroadcast();
        hyperchain.setTokenMultiplier(
            chainConfig.baseToken.gasPriceMultiplierNominator,
            chainConfig.baseToken.gasPriceMultiplierDenominator
        );

        if (chainConfig.pubdataPricingMode == PubdataPricingMode.Validium) {
            hyperchain.setPubdataPricingMode(PubdataPricingMode.Validium);
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);

        vm.broadcast();
        hyperchain.setPendingAdmin(config.chainAdmin);
        console.log("Owner for ", config.newDiamondProxy, "set to", config.chainAdmin);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "diamond_proxy_addr", config.newDiamondProxy);
        string memory toml = vm.serializeAddress("root", "chain_admin_addr", config.chainAdmin);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-hyperchain.toml");
        vm.writeToml(toml, path);
    }
}
