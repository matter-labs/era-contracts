// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "./Utils.sol";
import {L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehub.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

contract InitializeL2WethTokenScript is Script {
    using stdToml for string;

    struct Config {
        address deployerAddress;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
        uint256 eraChainId;
        address l1WethTokenAddr;
        string l1WethTokenName;
        string l1WethTokenSymbol;
        address bridgehubProxyAddr;
        address l2SharedBridgeAddr;
        address l2WethTokenProxyAddr;
        address l2WethTokenImplAddr;
        uint256 deployL2BridgeCounterpartGasLimit;
        uint256 requiredL2GasPricePerPubdata;
        uint256 gasMultiplier;
    }

    Config config;

    function run() public {
        initializeConfig();
        initializeL2WethToken();
    }

    function initializeConfig() internal {
        config.deployerAddress = msg.sender;

        // Parse some config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        string memory toml = vm.readFile(path);

        config.create2FactoryAddr = toml.readAddress("$.create2_factory_addr");
        config.create2FactorySalt = toml.readBytes32("$.create2_factory_salt");
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.bridgehubProxyAddr = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");

        // Parse some config from output of erc20 tokens deployment
        path = string.concat(root, "/script-out/output-deploy-erc20.toml");
        toml = vm.readFile(path);

        config.l1WethTokenAddr = toml.readAddress("$.tokens.WETH.address");
        config.l1WethTokenName = toml.readString("$.tokens.WETH.name");
        config.l1WethTokenSymbol = toml.readString("$.tokens.WETH.symbol");

        // Parse some config from custom config
        // TODO: read from L2 deployment output when available
        path = string.concat(root, "/script-config/config-initialize-l2-weth-token.toml");
        toml = vm.readFile(path);

        config.l2SharedBridgeAddr = toml.readAddress("$.l2_shared_bridge_addr");
        config.l2WethTokenProxyAddr = toml.readAddress("$.l2_weth_token_proxy_addr");
        config.l2WethTokenImplAddr = toml.readAddress("$.l2_weth_token_impl_addr");
        config.deployL2BridgeCounterpartGasLimit = toml.readUint("$.deploy_l2_bridge_counterpart_gas_limit");
        config.requiredL2GasPricePerPubdata = toml.readUint("$.required_l2_gas_price_per_pubdata");
        config.gasMultiplier = toml.readUint("$.gas_multiplier");
    }

    function initializeL2WethToken() internal {
        Bridgehub bridgehub = Bridgehub(config.bridgehubProxyAddr);

        uint256 gasPrice = Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]")) * config.gasMultiplier;
        uint256 requiredValueToInitializeBridge = bridgehub.l2TransactionBaseCost(
            config.eraChainId,
            gasPrice,
            config.deployL2BridgeCounterpartGasLimit,
            config.requiredL2GasPricePerPubdata
        );
        bytes memory l2Calldata = getL2Calldata();

        L2TransactionRequestDirect memory l2TransactionRequestDirect = L2TransactionRequestDirect({
            chainId: config.eraChainId,
            mintValue: requiredValueToInitializeBridge,
            l2Contract: config.l2WethTokenProxyAddr,
            l2Value: 0,
            l2Calldata: l2Calldata,
            l2GasLimit: config.deployL2BridgeCounterpartGasLimit,
            l2GasPerPubdataByteLimit: config.requiredL2GasPricePerPubdata,
            factoryDeps: new bytes[](0),
            refundRecipient: config.deployerAddress
        });

        vm.broadcast();
        bridgehub.requestL2TransactionDirect{value: requiredValueToInitializeBridge}(l2TransactionRequestDirect);

        console.log("L2 WETH token initialized");
    }

    function getL2Calldata() internal view returns (bytes memory) {
        // Low-level call is performed due to different solidity
        // compiler versions between L1 and L2
        // solhint-disable-next-line func-named-parameters
        bytes memory upgradeData = abi.encodeWithSignature(
            "initializeV2(string,string,address,address)",
            config.l1WethTokenName,
            config.l1WethTokenSymbol,
            config.l2SharedBridgeAddr,
            config.l1WethTokenAddr
        );
        bytes memory l2Calldata = abi.encodeCall(
            ITransparentUpgradeableProxy.upgradeToAndCall,
            (config.l2WethTokenImplAddr, upgradeData)
        );
        return l2Calldata;
    }
}
