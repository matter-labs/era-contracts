// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "../utils/Utils.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Call} from "contracts/governance/Common.sol";
import {AddressIntrospector} from "../utils/AddressIntrospector.sol";
import {BridgehubAddresses} from "../utils/Types.sol";
import {IDeployL2Contracts} from "contracts/script-interfaces/IDeployL2Contracts.sol";

contract DeployL2Script is Script, IDeployL2Contracts {
    using stdToml for string;

    Config internal config;
    DeployedContracts internal deployed;

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

    struct DeployedContracts {
        address forceDeployUpgraderAddress;
        address consensusRegistryImplementation;
        address consensusRegistryProxy;
        address multicall3;
        address timestampAsserter;
    }

    function run(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);

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

    function runWithLegacyBridge(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);
        deploy(true);
    }

    function deploy(bool legacyBridge) public {
        deployForceDeployer();
        deployConsensusRegistry();
        deployConsensusRegistryProxy();
        deployMulticall3();
        deployTimestampAsserter();

        saveOutput();
    }

    function runDefaultUpgrader(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);

        deployForceDeployer();

        saveOutput();
    }

    function runDeployConsensusRegistry(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);

        deployConsensusRegistry();
        deployConsensusRegistryProxy();

        saveOutput();
    }

    function runDeployMulticall3(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);

        deployMulticall3();

        saveOutput();
    }

    function runDeployTimestampAsserter(
        address _bridgehub,
        uint256 _chainId,
        address _governance,
        address _consensusRegistryOwner,
        uint256 _daValidatorType
    ) public {
        initializeConfig(_bridgehub, _chainId, _governance, _consensusRegistryOwner, _daValidatorType);

        deployTimestampAsserter();

        saveOutput();
    }

    function initializeConfig(
        address bridgehubAddress,
        uint256 chainId,
        address governance,
        address consensusRegistryOwner,
        uint256 daValidatorType
    ) internal {
        require(daValidatorType < 3, "Invalid DA validator type");

        config.bridgehubAddress = bridgehubAddress;
        config.governance = governance;
        config.consensusRegistryOwner = consensusRegistryOwner;
        config.chainId = chainId;
        config.validatorType = DAValidatorType(daValidatorType);

        // Use AddressIntrospector to get addresses from deployed contracts
        BridgehubAddresses memory bhAddresses = AddressIntrospector.getBridgehubAddresses(
            IL1Bridgehub(bridgehubAddress)
        );

        address assetRouter = address(IL1Bridgehub(bridgehubAddress).assetRouter());
        config.l1SharedBridgeProxy = assetRouter;
        config.erc20BridgeProxy = AddressIntrospector.getLegacyBridgeAddress(assetRouter);
        config.eraChainId = AddressIntrospector.getEraChainId(assetRouter);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "multicall3", deployed.multicall3);
        vm.serializeAddress("root", "consensus_registry_implementation", deployed.consensusRegistryImplementation);
        vm.serializeAddress("root", "consensus_registry_proxy", deployed.consensusRegistryProxy);
        vm.serializeAddress("root", "timestamp_asserter", deployed.timestampAsserter);
        string memory toml = vm.serializeAddress("root", "l2_default_upgrader", deployed.forceDeployUpgraderAddress);

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-contracts.toml");
        vm.writeToml(toml, path);
    }

    function deployForceDeployer() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        deployed.forceDeployUpgraderAddress = Utils.deployThroughL1({
            bytecode: ContractsBytecodesLib.getCreationCode("ForceDeployUpgrader"),
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
            bytecode: ContractsBytecodesLib.getCreationCode("ConsensusRegistry"),
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
            bytecode: ContractsBytecodesLib.getCreationCode("Multicall3"),
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
            bytecode: ContractsBytecodesLib.getCreationCode("TimestampAsserter"),
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
            bytecode: ContractsBytecodesLib.getCreationCode("TransparentUpgradeableProxy"),
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
