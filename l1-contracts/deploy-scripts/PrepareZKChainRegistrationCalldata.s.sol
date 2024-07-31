// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IStateTransitionManager, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Utils} from "./Utils.sol";

contract PrepareZKChainRegistrationCalldataScript is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;

    struct Config {
        address chainAdmin;
        address bridgehub;
        address stateTransitionProxy;
        uint256 chainId;
        uint256 eraChainId;
        uint256 bridgehubCreateNewChainSalt;
        address baseToken;
        bytes diamondCutData;
        address governance;
        address l1SharedBridgeProxy;
        address erc20BridgeProxy;
    }

    struct ContractsBytecodes {
        bytes beaconProxy;
        bytes l2SharedBridgeBytecode;
        bytes l2SharedBridgeProxyBytecode;
    }

    Config config;
    ContractsBytecodes bytecodes;

    function run() public {
        console.log("Preparing ZK chain registration calldata");

        initializeConfig();

        checkBaseTokenAddress();

        IGovernance.Call[] memory calls;
        uint256 cnt = 0;
        if (!IBridgehub(config.bridgehub).tokenIsRegistered(config.baseToken)) {
            calls = new IGovernance.Call[](2);
            IGovernance.Call memory baseTokenRegistrationCall = prepareRegisterBaseTokenCall();
            calls[cnt] = baseTokenRegistrationCall;
            cnt++;
        } else {
            calls = new IGovernance.Call[](1);
        }

        IGovernance.Call memory registerChainCall = prepareRegisterHyperchainCall();
        calls[cnt] = registerChainCall;
        cnt++;

        address l2SharedBridgeProxy = computeL2BridgeAddress();
        IGovernance.Call memory initChainCall = prepareInitializeChainGovernanceCall(l2SharedBridgeProxy);

        scheduleTransparentCalldata(calls, initChainCall);
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/prepare-registration-calldata.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub_proxy_addr");
        config.stateTransitionProxy = toml.readAddress("$.deployed_addresses.state_transition_proxy_addr");
        config.l1SharedBridgeProxy = toml.readAddress("$.deployed_addresses.l1_shared_bridge_proxy_addr");
        config.erc20BridgeProxy = toml.readAddress("$.deployed_addresses.erc20_bridge_proxy_addr");

        config.chainId = toml.readUint("$.chain.chain_id");
        config.eraChainId = toml.readUint("$.chain.era_chain_id");
        config.chainAdmin = toml.readAddress("$.chain.admin");
        config.diamondCutData = toml.readBytes("$.chain.diamond_cut_data");
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.governance = toml.readAddress("$.chain.governance_addr");

        bytecodes.l2SharedBridgeBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2SharedBridge.sol/L2SharedBridge.json"
        );

        bytecodes.l2SharedBridgeProxyBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
        bytecodes.beaconProxy = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
        );
    }

    function checkBaseTokenAddress() internal view {
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

    function prepareRegisterBaseTokenCall() internal returns (IGovernance.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        bytes memory data = abi.encodeCall(bridgehub.addToken, (config.baseToken));

        return IGovernance.Call({target: config.bridgehub, value: 0, data: data});
    }

    function computeL2BridgeAddress() internal returns (address) {
        bytes32 salt = "";
        bytes32 bridgeBytecodeHash = L2ContractHelper.hashL2Bytecode(bytecodes.l2SharedBridgeBytecode);
        bytes memory bridgeConstructorData = abi.encode(config.eraChainId);

        address deployer;
        address l2GovernorAddress;

        if (isEOA(msg.sender)) {
            deployer = msg.sender;
        } else {
            deployer = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        }

        if (isEOA(config.governance)) {
            l2GovernorAddress = config.governance;
        } else {
            l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        }

        address implContractAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            salt,
            bridgeBytecodeHash,
            keccak256(bridgeConstructorData)
        );

        console.log("Computed L2 bridge impl address:", implContractAddress);
        console.log("Bridge bytecode hash:");
        console.logBytes32(bridgeBytecodeHash);
        console.log("Bridge constructor data:");
        console.logBytes(bridgeConstructorData);
        console.log("Sender:", msg.sender);

        bytes32 l2StandardErc20BytecodeHash = L2ContractHelper.hashL2Bytecode(bytecodes.beaconProxy);

        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            "initialize(address,address,bytes32,address)",
            config.l1SharedBridgeProxy,
            config.erc20BridgeProxy,
            l2StandardErc20BytecodeHash,
            l2GovernorAddress
        );

        bytes memory l2SharedBridgeProxyConstructorData = abi.encode(
            implContractAddress,
            l2GovernorAddress,
            proxyInitializationParams
        );

        address proxyContractAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            salt,
            L2ContractHelper.hashL2Bytecode(bytecodes.l2SharedBridgeProxyBytecode),
            keccak256(l2SharedBridgeProxyConstructorData)
        );

        console.log("Computed L2 bridge proxy address:", proxyContractAddress);
        console.log("L1 shared bridge proxy:", config.l1SharedBridgeProxy);
        console.log("L1 ERC20 bridge proxy:", config.erc20BridgeProxy);
        console.log("L2 governor addr:", l2GovernorAddress);

        return proxyContractAddress;
    }

    function prepareRegisterHyperchainCall() internal returns (IGovernance.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainId,
                config.stateTransitionProxy,
                config.baseToken,
                config.bridgehubCreateNewChainSalt,
                config.chainAdmin,
                config.diamondCutData
            )
        );

        return IGovernance.Call({target: config.bridgehub, value: 0, data: data});
    }

    function prepareInitializeChainGovernanceCall(
        address l2SharedBridgeProxy
    ) internal returns (IGovernance.Call memory) {
        L1SharedBridge bridge = L1SharedBridge(config.l1SharedBridgeProxy);

        bytes memory data = abi.encodeCall(bridge.initializeChainGovernance, (config.chainId, l2SharedBridgeProxy));

        return IGovernance.Call({target: config.l1SharedBridgeProxy, value: 0, data: data});
    }

    function scheduleTransparentCalldata(
        IGovernance.Call[] memory calls,
        IGovernance.Call memory initChainGovCall
    ) internal {
        IGovernance governance = IGovernance(config.governance);

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(config.bridgehubCreateNewChainSalt)
        });

        bytes memory scheduleCalldata = abi.encodeCall(governance.scheduleTransparent, (operation, 0));
        bytes memory executeCalldata = abi.encodeCall(governance.execute, (operation));
        console.log("Completed");

        IGovernance.Call[] memory initChainGovArray = new IGovernance.Call[](1);
        initChainGovArray[0] = initChainGovCall;

        IGovernance.Operation memory operation2 = IGovernance.Operation({
            calls: initChainGovArray,
            predecessor: bytes32(0),
            salt: bytes32(config.bridgehubCreateNewChainSalt)
        });

        bytes memory scheduleCalldata2 = abi.encodeCall(governance.scheduleTransparent, (operation2, 0));
        bytes memory executeCalldata2 = abi.encodeCall(governance.execute, (operation2));

        saveOutput(scheduleCalldata, executeCalldata, scheduleCalldata2, executeCalldata2);
    }

    function saveOutput(
        bytes memory schedule,
        bytes memory execute,
        bytes memory schedule2,
        bytes memory execute2
    ) internal {
        vm.serializeBytes("root", "scheduleCalldataStageOne", schedule);
        vm.serializeBytes("root", "executeCalldataStageOne", execute);
        vm.serializeBytes("root", "scheduleCalldataStageTwo", schedule2);
        string memory toml = vm.serializeBytes("root", "executeCalldataStageTwo", execute2);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-prepare-registration-calldata.toml");
        vm.writeToml(toml, path);
    }

    function isEOA(address _addr) private returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }

        return (size == 0);
    }
}

// Done by the chain admin separately from this script:
// - add validators
// - deploy L2 contracts
// - set pubdata sending mode
// - set base token gas price multiplier
