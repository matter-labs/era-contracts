// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "../utils/Utils.sol";
import {IL1Bridgehub, L2TransactionRequestDirect} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {PermanentValuesHelper} from "../utils/PermanentValuesHelper.sol";

contract InitializeL2WethTokenScript is Script {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
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

    Config internal config;

    function run(address _bridgehub) public {
        initializeConfig(_bridgehub);
        initializeL2WethToken();
    }

    function initializeConfig(address bridgehubProxyAddr) internal {
        config.deployerAddress = msg.sender;

        // Parse some config from output of l1 deployment
        string memory root = vm.projectRoot();

        // Read create2 factory values from permanent values file
        // Note: This script uses $.contracts prefix instead of $.permanent_contracts
        (address create2FactoryAddr, bytes32 create2FactorySalt) = PermanentValuesHelper.getPermanentValuesWithPrefix(
            vm,
            PermanentValuesHelper.getPermanentValuesPath(vm),
            "$.contracts"
        );
        config.create2FactoryAddr = create2FactoryAddr;
        config.create2FactorySalt = create2FactorySalt;

        // Use AddressIntrospector to get addresses from deployed contracts
        BridgehubAddresses memory bhAddresses = AddressIntrospector.getBridgehubAddresses(
            IL1Bridgehub(bridgehubProxyAddr)
        );
        config.eraChainId = AddressIntrospector.getEraChainId(bhAddresses.assetRouter);
        config.proxies.bridgehubAddr = bridgehubProxyAddr;

        // Parse some config from output of erc20 tokens deployment
        string memory path = string.concat(root, "/script-out/output-deploy-erc20.toml");
        string memory toml = vm.readFile(path);

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
        IL1Bridgehub bridgehub = IL1Bridgehub(config.proxies.bridgehubAddr);

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
