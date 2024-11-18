// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {Utils} from "./Utils.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        // Ecosystem parameters
        address bridgehub;
        address stateTransitionProxy;
        address validatorTimelock;
        address l1SharedBridgeProxy;
        bytes diamondCutData;
        // Chain parameters
        uint256 chainId;
        bool validiumMode;
        address owner;
        address operator;
        address blobOperator;
        address tokenMultiplierSetter;
        address baseToken;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
        // Create2 parameters
        address create2Factory;
        bytes32 create2FactorySalt;
        // Chain contracts
        address chainAdmin;
        address newDiamondProxy;
        address l2SharedBridgeProxy;
    }

    Config internal config;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        deployChainAdmin();
        createHyperchain();
        configureHyperchain();

        saveOutput();
    }

    function runDeployChainAdmin() public returns (address) {
        initializeConfig();
        deployChainAdmin();
        saveOutput();
    }

    function runCreateHyperchain() public {
        initializeConfig();
        createHyperchain();
        saveOutput();
    }

    function runConfigureHyperchain() public {
        initializeConfig();
        configureHyperchain();
    }

    function runRegisterL2SharedBridge() public {
        initializeConfig();
        registerL2SharedBridge();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-hyperchain.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alphabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Ecosystem parameters
        config.bridgehub = toml.readAddress("$.ecosystem.bridgehub_proxy_addr");
        config.stateTransitionProxy = toml.readAddress("$.ecosystem.state_transition_proxy_addr");
        config.validatorTimelock = toml.readAddress("$.ecosystem.validator_timelock_addr");
        config.l1SharedBridgeProxy = toml.readAddress("$.ecosystem.l1_shared_bridge_proxy_addr");
        config.diamondCutData = toml.readBytes("$.ecosystem.diamond_cut_data");
        // Chain parameters
        config.chainId = toml.readUint("$.chain.chain_id");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.owner = toml.readAddress("$.chain.owner_addr");
        config.operator = toml.readAddress("$.chain.operator_addr");
        config.blobOperator = toml.readAddress("$.chain.blob_operator_addr");
        config.tokenMultiplierSetter = toml.readAddress("$.chain.token_multiplier_setter_addr");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_nominator")
        );
        config.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_denominator")
        );
        // Create2 parameters
        if (vm.keyExistsToml(toml, "$.create2_factory_addr")) {
            config.create2Factory = toml.readAddress("$.create2_factory_addr");
        }
        if (config.create2Factory == address(0)) {
            config.create2Factory = DETERMINISTIC_CREATE2_ADDRESS;
        }
        config.create2FactorySalt = toml.readBytes32("$.create2_factory_salt");
        // Chain contracts
        config.chainAdmin = toml.readAddress("$.chain_admin_addr");
        config.newDiamondProxy = toml.readAddress("$.diamond_proxy_addr");
        config.l2SharedBridgeProxy = toml.readAddress("$.l2_shared_bridge_proxy_addr");

        checkTokenAddress();
    }

    function checkTokenAddress() internal view {
        if (config.baseToken == address(0)) {
            revert("Token address is not set");
        }
        // Check if it's ethereum address
        if (config.baseToken == ADDRESS_ONE) {
            return;
        }
        if (config.baseToken.code.length == 0) {
            revert("Token address is not a contract address");
        }
        console.log("Using base token address:", config.baseToken);
    }

    function deployChainAdmin() internal {
        bytes memory bytecode = abi.encodePacked(
            type(ChainAdmin).creationCode,
            abi.encode(msg.sender, config.tokenMultiplierSetter)
        );
        address contractAddress = Utils.deployViaCreate2(
            bytecode,
            config.create2FactorySalt,
            config.create2Factory
        );
        console.log("ChainAdmin deployed at:", contractAddress);
        config.chainAdmin = contractAddress;
    }

    function createHyperchain() internal {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        uint8 maxCalls = 2;
        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](maxCalls);

        uint8 numCalls = 0;
        // Register base token
        if (!bridgehub.tokenIsRegistered(config.baseToken)) {
            calls[numCalls++] = prepareAddTokenCall();
        }
        // Create new chain
        calls[numCalls++] = prepareCreateNewChainCall();

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }

        vm.startBroadcast();
        IChainAdmin(bridgehub.admin()).multicall(calls, true);
        vm.stopBroadcast();

        config.newDiamondProxy = address(bridgehub.getHyperchain(config.chainId));
        if (config.newDiamondProxy == address(0)) {
            revert("Diamond proxy address not found");
        }
        console.log("Hyperchain diamond proxy deployed at:", config.newDiamondProxy);
    }

    function configureHyperchain() internal {
        uint8 maxCalls = 4;
        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](maxCalls);

        uint8 numCalls = 0;
        // Set operator
        calls[numCalls++] = prepareAddValidatorCall(config.operator);
        // Set blob operator
        calls[numCalls++] = prepareAddValidatorCall(config.blobOperator);
        // Set base token token multiplier params
        calls[numCalls++] = prepareSetBaseTokenMultiplierCall();
        // Set pubdata mode
        if (config.validiumMode) {
            calls[numCalls++] = prepareSetValidiumPubdataPricingModeCall();
        }

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }

        ChainAdmin chainAdmin = ChainAdmin(payable(config.chainAdmin));
        vm.startBroadcast();
        // Multicall to configure new chain
        chainAdmin.multicall(calls, true);
        // Set token multiplier setter
        if (config.baseToken != ADDRESS_ONE && chainAdmin.tokenMultiplierSetter() != config.tokenMultiplierSetter) {
            chainAdmin.setTokenMultiplierSetter(config.tokenMultiplierSetter);
        }
        // Transfer ownership to the chain owner
        if (chainAdmin.owner() != config.owner) {
            chainAdmin.transferOwnership(config.owner);
        }
        vm.stopBroadcast();

        console.log("Hyperchain configured");
    }

    function prepareAddTokenCall() internal view returns (IChainAdmin.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);
        return IChainAdmin.Call({
            target: config.bridgehub,
            value: 0,
            data: abi.encodeCall(bridgehub.addToken, (config.baseToken))
        });
    }

    function prepareCreateNewChainCall() internal view returns (IChainAdmin.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainId,
                config.stateTransitionProxy,
                config.baseToken,
                uint256(0), // salt (unused)
                config.chainAdmin,
                config.diamondCutData
            )
        );
        return IChainAdmin.Call({target: config.bridgehub, value: 0, data: data});
    }

    function prepareAddValidatorCall(address operator) internal view returns (IChainAdmin.Call memory) {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);
        return IChainAdmin.Call({
            target: config.validatorTimelock,
            value: 0,
            data: abi.encodeCall(validatorTimelock.addValidator, (config.chainId, operator))
        });
    }

    function prepareSetBaseTokenMultiplierCall() internal view returns (IChainAdmin.Call memory) {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);
        return IChainAdmin.Call({
            target: config.newDiamondProxy,
            value: 0,
            data: abi.encodeCall(
                hyperchain.setTokenMultiplier,
                (config.baseTokenGasPriceMultiplierNominator, config.baseTokenGasPriceMultiplierDenominator)
            )
        });
    }

    function prepareSetValidiumPubdataPricingModeCall() internal view returns (IChainAdmin.Call memory) {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);
        return IChainAdmin.Call({
            target: config.newDiamondProxy,
            value: 0,
            data: abi.encodeCall(hyperchain.setPubdataPricingMode, (PubdataPricingMode.Validium))
        });
    }

    function registerL2SharedBridge() internal {
        L1SharedBridge l1Bridge = L1SharedBridge(config.l1SharedBridgeProxy);
        Utils.chainAdminMulticall({
            _chainAdmin: l1Bridge.admin(),
            _target: config.l1SharedBridgeProxy,
            _data: abi.encodeCall(l1Bridge.initializeChainGovernance, (config.chainId, config.l2SharedBridgeProxy)),
            _value: 0
        });
    }
    
    function saveOutput() internal {
        vm.serializeAddress("root", "diamond_proxy_addr", config.newDiamondProxy);
        string memory toml = vm.serializeAddress("root", "chain_admin_addr", config.chainAdmin);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-hyperchain.toml");
        vm.writeToml(toml, path);
    }
}
