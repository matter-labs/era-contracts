// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Call} from "contracts/governance/Common.sol";
// import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

contract DeployL2Script is Script {
    using stdToml for string;

    Config internal config;
    DeployedContrats internal deployed;

    enum DAValidatorType {
        Rollup,
        NoDA,
        Avail
    }

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        uint256 eraChainId;
        uint256 chainId;
        address l1SharedBridgeProxy;
        address bridgehubAddress;
        address governance;
        address erc20BridgeProxy;
        address chainRegistrar;
        address proposalAuthor;
        DAValidatorType validatorType;
        // The owner of the contract sets the validator/attester weights.
        // Can be the developer multisig wallet on mainnet.
        address consensusRegistryOwner;
    }

    struct DeployedContrats {
        address l2DaValidatorAddress;
        address forceDeployUpgraderAddress;
        address consensusRegistryImplementation;
        address consensusRegistryProxy;
        address multicall3;
        address timestampAsserter;
    }

    function run() public {
        initializeConfig();

        deploy(false);
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) internal {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable2Step ownable = Ownable2Step(governanceAddr);

        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startPrank(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        // We assume that the total value is 0
        governance.execute{value: 0}(operation);
        vm.stopPrank();
    }

    function runWithLegacyBridge() public {
        initializeConfig();
        deploy(true);
    }

    function deploy(bool legacyBridge) public {
        // Note, that it is important that the first transaction is for setting the L2 DA validator
        deployL2DaValidator();

        deployForceDeployer();
        deployConsensusRegistry();
        deployConsensusRegistryProxy();
        deployMulticall3();
        deployTimestampAsserter();

        saveOutput();
    }

    function runDefaultUpgrader() public {
        initializeConfig();

        deployForceDeployer();

        saveOutput();
    }

    function runDeployConsensusRegistry() public {
        initializeConfig();

        deployConsensusRegistry();
        deployConsensusRegistryProxy();

        saveOutput();
    }

    function runDeployMulticall3() public {
        initializeConfig();

        deployMulticall3();

        saveOutput();
    }

    function runDeployTimestampAsserter() public {
        initializeConfig();

        deployTimestampAsserter();

        saveOutput();
    }

    function runDeployL2DAValidator() public {
        initializeConfig();

        deployL2DaValidator();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-contracts.toml");
        string memory toml = vm.readFile(path);
        config.bridgehubAddress = toml.readAddress("$.bridgehub");
        config.governance = toml.readAddress("$.governance");
        config.l1SharedBridgeProxy = toml.readAddress("$.l1_shared_bridge");
        config.erc20BridgeProxy = toml.readAddress("$.erc20_bridge");
        config.consensusRegistryOwner = toml.readAddress("$.consensus_registry_owner");
        //config.chainRegistrar = toml.readAddress("$.chain_registrar");
        //config.proposalAuthor = toml.readAddress("$.proposal_author");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");

        uint256 validatorTypeUint = toml.readUint("$.da_validator_type");
        require(validatorTypeUint < 3, "Invalid DA validator type");
        config.validatorType = DAValidatorType(validatorTypeUint);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "l2_da_validator_address", deployed.l2DaValidatorAddress);
        vm.serializeAddress("root", "multicall3", deployed.multicall3);
        vm.serializeAddress("root", "consensus_registry_implementation", deployed.consensusRegistryImplementation);
        vm.serializeAddress("root", "consensus_registry_proxy", deployed.consensusRegistryProxy);
        vm.serializeAddress("root", "timestamp_asserter", deployed.timestampAsserter);
        string memory toml = vm.serializeAddress("root", "l2_default_upgrader", deployed.forceDeployUpgraderAddress);

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployL2DaValidator() internal {
        bytes memory bytecode;
        if (config.validatorType == DAValidatorType.Rollup) {
            bytecode = L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        } else if (config.validatorType == DAValidatorType.NoDA) {
            bytecode = L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode();
        } else if (config.validatorType == DAValidatorType.Avail) {
            bytecode = L2ContractsBytecodesLib.readAvailL2DAValidatorBytecode();
        } else {
            revert("Invalid DA validator type");
        }

        deployed.l2DaValidatorAddress = Utils.deployThroughL1Deterministic({
            bytecode: bytecode,
            constructorargs: bytes(""),
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployForceDeployer() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        deployed.forceDeployUpgraderAddress = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readForceDeployUpgraderBytecode(),
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    // Deploy the ConsensusRegistry implementation and save its address into the config.
    function deployConsensusRegistry() internal {
        // ConsensusRegistry.sol doesn't have a constructor, just an initializer.
        bytes memory constructorData = "";

        deployed.consensusRegistryImplementation = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readConsensusRegistryBytecode(),
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployMulticall3() internal {
        // Multicall3 doesn't have a constructor.
        bytes memory constructorData = "";

        deployed.multicall3 = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readMulticall3Bytecode(),
            constructorargs: constructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    function deployTimestampAsserter() internal {
        deployed.timestampAsserter = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readTimestampAsserterBytecode(),
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }

    // Deploy a transparent upgradable proxy for the already deployed consensus registry
    // implementation and save its address into the config.
    function deployConsensusRegistryProxy() internal {
        // Admin for the proxy
        address l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);

        // Call ConsensusRegistry::initialize with the initial owner.
        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            "initialize(address)",
            config.consensusRegistryOwner
        );

        bytes memory consensusRegistryProxyConstructorData = abi.encode(
            deployed.consensusRegistryImplementation, // _logic
            l2GovernorAddress, // admin_
            proxyInitializationParams // _data
        );

        deployed.consensusRegistryProxy = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode(),
            constructorargs: consensusRegistryProxyConstructorData,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubAddress,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
    }
}
