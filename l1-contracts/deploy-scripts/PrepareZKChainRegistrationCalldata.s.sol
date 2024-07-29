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

        IGovernance.Call memory baseTokenRegistrationCall;
        if (!IBridgehub(config.bridgehub).tokenIsRegistered(config.baseToken)) {
            baseTokenRegistrationCall = prepareRegisterBaseTokenCall();
        }

        (IGovernance.Call[] memory deployL2Calls, address l2SharedBridgeProxy) = prepareDeployL2BridgeCalls();

        uint256 counter = 0;
        uint256 callsSize = 3 + deployL2Calls.length;
        if (baseTokenRegistrationCall.target != address(0)) {
            callsSize++;
        }

        IGovernance.Call[] memory calls = new IGovernance.Call[](callsSize);
        if (baseTokenRegistrationCall.target != address(0)) {
            calls[counter++] = baseTokenRegistrationCall;
        }

        calls[counter++] = prepareSetChainCreationParamsCall();
        calls[counter++] = prepareRegisterHyperchainCall();
        for (uint256 i = 0; i < deployL2Calls.length; i++) {
            calls[counter++] = deployL2Calls[i];
        }
        calls[counter] = prepareInitializeChainGovernanceCall(l2SharedBridgeProxy);

        scheduleTransparentCalldata(calls);
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

    function prepareRegisterBaseTokenCall() internal view returns (IGovernance.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);

        bytes memory data = abi.encodeCall(bridgehub.addToken, (config.baseToken));

        return IGovernance.Call({target: config.bridgehub, value: 0, data: data});
    }

    function prepareDeployL2BridgeCalls() internal returns (IGovernance.Call[] memory, address) {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytecodes.beaconProxy;

        address l2GovernorAddress = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        bytes memory constructorArgs = abi.encode(config.eraChainId);

        IGovernance.Call[] memory callsImpl = Utils.getDeployThroughL1Calldata({
            bytecode: bytecodes.l2SharedBridgeBytecode,
            constructorargs: constructorArgs,
            l2GasLimit: 1000000,
            factoryDeps: factoryDeps,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy,
            baseToken: config.baseToken
        });

        address implAddress = L2ContractHelper.computeCreate2Address(
            l2GovernorAddress,
            "", // salt
            L2ContractHelper.hashL2Bytecode(bytecodes.l2SharedBridgeBytecode),
            keccak256(constructorArgs)
        );

        console.log("Computed L2 bridge impl address:", implAddress);

        // solhint-disable-next-line func-named-parameters
        bytes memory proxyInitializationParams = abi.encodeWithSignature(
            "initialize(address,address,bytes32,address)",
            config.l1SharedBridgeProxy,
            config.erc20BridgeProxy,
            L2ContractHelper.hashL2Bytecode(bytecodes.beaconProxy),
            l2GovernorAddress
        );

        constructorArgs = abi.encode(
            implAddress,
            l2GovernorAddress,
            proxyInitializationParams
        );

        IGovernance.Call[] memory callsProxy = Utils.getDeployThroughL1Calldata({
            bytecode: bytecodes.l2SharedBridgeProxyBytecode,
            constructorargs: constructorArgs,
            l2GasLimit: 1000000,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy,
            baseToken: config.baseToken
        });

        address proxyAddr = L2ContractHelper.computeCreate2Address(
            l2GovernorAddress,
            "", // salt
            L2ContractHelper.hashL2Bytecode(bytecodes.l2SharedBridgeProxyBytecode),
            keccak256(constructorArgs)
        );

        console.log("Computed L2 bridge proxy address:", proxyAddr);

        IGovernance.Call[] memory calls = new IGovernance.Call[](callsImpl.length + callsProxy.length);
        for (uint256 i = 0; i < calls.length; i++) {
            if (i < callsImpl.length) {
                calls[i] = callsImpl[i];
            } else {
                calls[i] = callsProxy[i - callsImpl.length];
            }
        }

        return (calls, proxyAddr);
    }

    function prepareSetChainCreationParamsCall() internal view returns (IGovernance.Call memory) {
        ChainCreationParams memory params = ChainCreationParams({
            genesisUpgrade: 0x3dDD7ED2AeC0758310A4C6596522FCAeD108DdA2,
            genesisBatchHash: bytes32(0xabdb766b18a479a5c783a4b80e12686bc8ea3cc2d8a3050491b701d72370ebb5),
            genesisIndexRepeatedStorageChanges: 54,
            genesisBatchCommitment: bytes32(0x2d00e5f8d77afcebf58a6b82ae56ba967566fe7dfbcb6760319fb0d215d18ffd),
            diamondCut: abi.decode(config.diamondCutData, (Diamond.DiamondCutData))
        });

        bytes memory data = abi.encodeCall(IStateTransitionManager.setChainCreationParams, (params));

        return IGovernance.Call({target: config.stateTransitionProxy, value: 0, data: data});
    }

    function prepareRegisterHyperchainCall() internal view returns (IGovernance.Call memory) {
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

    function prepareInitializeChainGovernanceCall(address l2SharedBridgeProxy) internal view returns (IGovernance.Call memory) {
        L1SharedBridge bridge = L1SharedBridge(config.l1SharedBridgeProxy);

        bytes memory data = abi.encodeCall(bridge.initializeChainGovernance, (config.chainId, l2SharedBridgeProxy));

        return IGovernance.Call({target: config.l1SharedBridgeProxy, value: 0, data: data});
    }

    function scheduleTransparentCalldata(IGovernance.Call[] memory calls) internal {
        IGovernance governance = IGovernance(config.governance);

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(config.bridgehubCreateNewChainSalt)
        });

        bytes memory scheduleCalldata = abi.encodeCall(governance.scheduleTransparent, (operation, 0));
        bytes memory executeCalldata = abi.encodeCall(governance.execute, (operation));
        console.log("Completed");

        saveOutput(scheduleCalldata, executeCalldata);
    }

    function saveOutput(bytes memory schedule, bytes memory execute) internal {
        vm.serializeBytes("root", "scheduleCalldata", schedule);
        string memory toml = vm.serializeBytes("root", "executeCalldata", execute);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-prepare-registration-calldata.toml");
        vm.writeToml(toml, path);
    }

    function isEOA(address _addr) private view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }

        return (size == 0);
    }
}

// Done by the chain admin:
// - add validators
// - set pubdata sending mode
// - set base token gas price multiplier
