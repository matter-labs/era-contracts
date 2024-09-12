pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils, L2ContractsBytecodes} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
// import {L1AssetRouter} from "contracts/bridge/L1AssetRouter.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config internal config;
    DeployedContrats internal deployed;
    L2ContractsBytecodes internal contracts;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 eraChainId;
        uint256 chainId;
        address l1SharedBridgeProxy;
        address bridgehubAddress;
        address governance;
        address erc20BridgeProxy;
        bool validiumMode;
        // Not used right now, maybe will be needed later
        address consensusRegistryOwner;
    }

    struct DeployedContrats {
        address l2DaValidatorAddress;
        address forceDeployUpgraderAddress;
    }

    function run() public {
        initializeConfig();
        loadContracts();

        // Note, that it is important that the first transaction is for setting the L2 DA validator
        deployL2DaValidator();

        deployForceDeployer();

        saveOutput();
    }

    function runDeploySharedBridge() public {
        initializeConfig();
        loadContracts();

        saveOutput();
    }

    function runDefaultUpgrader() public {
        initializeConfig();
        loadContracts();

        deployForceDeployer();

        saveOutput();
    }

    function loadContracts() internal {
        contracts = Utils.readL2ContractsBytecodes();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-contracts.toml");
        string memory toml = vm.readFile(path);
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "l2_da_validator_address", deployed.l2DaValidatorAddress);
        string memory toml = vm.serializeAddress("root", "l2_default_upgrader", deployed.forceDeployUpgraderAddress);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployL2DaValidator() internal {
        bytes memory bytecode;
        if (config.validiumMode) {
            bytecode = contracts.validiumL2DAValidator;
        } else {
            bytecode = contracts.rollupL2DAValidator;
        }

        deployed.l2DaValidatorAddress = Utils.deployThroughL1({
            bytecode: contracts.l2SharedBridgeBytecode,
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployForceDeployer() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        config.forceDeployUpgraderAddress = Utils.deployThroughL1({
            bytecode: contracts.forceDeployUpgrader,
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }
}
