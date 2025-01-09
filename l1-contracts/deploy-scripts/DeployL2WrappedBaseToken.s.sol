// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {Utils} from "./Utils.sol";

import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployL2WrappedBaseToken is Script {
    using stdToml for string;

    address constant ETH_BASE_TOKEN = 0x0000000000000000000000000000000000000001;
    uint256 internal constant MAX_PRIORITY_TX_GAS = 3600000;

    Config public config;
    ContractBytecodes internal bytecodes;
    OutputConfig public output;

    struct Config {
        uint256 chainId;
        address bridgehubProxy;
        // Derived:
        address baseToken;
        string wrappedBaseTokenName;
        string wrappedBaseTokenSymbol;
        address l1SharedBridgeProxy;
        address l2SharedBridgeProxy;
        address l2ProxyAdminOwner;
    }

    struct ContractBytecodes {
        bytes l2WrappedBaseToken;
        bytes transparentUpgradeableProxy;
        bytes proxyAdmin;
    }

    struct OutputConfig {
        address proxyAdmin;
        address l2WrappedBaseTokenImplementation;
        address l2WrappedBaseTokenProxy;
        bytes l2WrappedBaseTokenProxyConstructorData;
    }

    function run() public {
        initializeConfig();
        loadBytecodes();

        deployProxyAdmin();
        deployL2WrappedBaseTokenImplementation();
        deployL2WrappedBaseTokenProxy();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-l2-wrapped-base-token.toml");
        string memory toml = vm.readFile(path);

        config.chainId = toml.readUint("$.chain_id");
        config.bridgehubProxy = toml.readAddress("$.bridgehub_proxy");
        console.log("Chain ID:", config.chainId);
        console.log("Bridgehub proxy:", config.bridgehubProxy);

        // Derived:
        Bridgehub bridgehub = Bridgehub(config.bridgehubProxy);
        config.l1SharedBridgeProxy = address(bridgehub.sharedBridge());
        L1SharedBridge l1SharedBridge = L1SharedBridge(address(bridgehub.sharedBridge()));
        config.l2SharedBridgeProxy = address(l1SharedBridge.l2BridgeAddress(config.chainId));

        config.baseToken = address(bridgehub.baseToken(config.chainId));
        if (config.baseToken == address(0)) {
            revert("Base token not found");
        }
        if (config.baseToken == ETH_BASE_TOKEN) {
            config.wrappedBaseTokenName = "Wrapped Ether";
            config.wrappedBaseTokenSymbol = "WETH";
        } else {
            ERC20 erc20 = ERC20(config.baseToken);
            config.wrappedBaseTokenName = string.concat("Wrapped ", erc20.name());
            config.wrappedBaseTokenSymbol = string.concat("w", erc20.symbol());
        }

        address owner = address(l1SharedBridge.owner());
        if (Utils.isEOA(owner)) {
            config.l2ProxyAdminOwner = owner;
        } else {
            config.l2ProxyAdminOwner = AddressAliasHelper.applyL1ToL2Alias(owner);
        }
    }

    function loadBytecodes() internal {
        bytecodes.l2WrappedBaseToken = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/L2WrappedBaseToken.sol/L2WrappedBaseToken.json"
        );
        bytecodes.transparentUpgradeableProxy = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
        );
        bytecodes.proxyAdmin = Utils.readFoundryBytecode(
            "/../l2-contracts/zkout/ProxyAdmin.sol/ProxyAdmin.json"
        );
    }

    function deployL2WrappedBaseTokenImplementation() internal {
        output.l2WrappedBaseTokenImplementation = Utils.deployThroughL1Deterministic({
            bytecode: bytecodes.l2WrappedBaseToken,
            constructorargs: "",
            create2salt: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubProxy,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        console.log("L2WrappedBaseTokenImplementation deployed at:", output.l2WrappedBaseTokenImplementation);
    }

    function deployL2WrappedBaseTokenProxy() internal {
        bytes memory proxyInitializationData = abi.encodeWithSignature(
            // name, symbol, l2Bridge, l1Address
            "initializeV2(string,string,address,address)",
            config.wrappedBaseTokenName,
            config.wrappedBaseTokenSymbol,
            config.l2SharedBridgeProxy,
            config.baseToken
        );

        bytes memory l2WrappedBaseTokenProxyConstructorData = abi.encode(
            output.l2WrappedBaseTokenImplementation, // logic
            output.proxyAdmin, // admin
            proxyInitializationData // data
        );

        output.l2WrappedBaseTokenProxy = Utils.deployThroughL1Deterministic({
            bytecode: bytecodes.transparentUpgradeableProxy,
            constructorargs: l2WrappedBaseTokenProxyConstructorData,
            create2salt: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubProxy,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        output.l2WrappedBaseTokenProxyConstructorData = l2WrappedBaseTokenProxyConstructorData;
        console.log("L2WrappedBaseTokenProxy deployed at:", output.l2WrappedBaseTokenProxy);
        console.log("L2WrappedBaseTokenProxy constructor args:");
        console.logBytes(l2WrappedBaseTokenProxyConstructorData);
    }

    function deployProxyAdmin() internal {
        output.proxyAdmin = Utils.deployThroughL1({
            bytecode: bytecodes.proxyAdmin,
            constructorargs: "",
            create2salt: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubProxy,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });

        // Transfer ownership of ProxyAdmin to l2ProxyAdminOwner
        bytes memory transferCalldata = abi.encodeWithSignature(
            "transferOwnership(address)",
            config.l2ProxyAdminOwner
        );
        Utils.runL1L2Transaction({
            l2Calldata: transferCalldata,
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            l2Value: 0,
            factoryDeps: new bytes[](0),
            dstAddress: output.proxyAdmin,
            chainId: config.chainId,
            bridgehubAddress: config.bridgehubProxy,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        console.log("ProxyAdmin deployed at:", output.proxyAdmin);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "proxy_admin", output.proxyAdmin);
        vm.serializeAddress("root", "l2_wrapped_base_token_implementation", output.l2WrappedBaseTokenImplementation);
        vm.serializeAddress("root", "l2_wrapped_base_token_proxy", output.l2WrappedBaseTokenProxy);
        string memory toml = vm.serializeBytes("root", "l2_wrapped_base_token_proxy_constructor_data", output.l2WrappedBaseTokenProxyConstructorData);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l2-wrapped-base-token.toml");
        vm.writeToml(toml, path);
    }
}
