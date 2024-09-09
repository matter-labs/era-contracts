// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// This scripts is only for developer
contract SetupLegacybridge is Script {
    using stdToml for string;

    function run() {}

    function deploySharedBridgeImplementation() internal {
        bytes memory bytecode = abi.encodePacked(
            type(L1SharedBridge).creationCode,
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridgehub.bridgehubProxy,
                config.eraChainId,
                addresses.stateTransition.diamondProxy
            )
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeImplementation deployed at:", contractAddress);
        addresses.bridges.sharedBridgeImplementation = contractAddress;
    }

    function deploySharedBridgeProxy() internal {
        bytes memory initCalldata = abi.encodeCall(L1SharedBridge.initialize, (config.deployerAddress));
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(addresses.bridges.sharedBridgeImplementation, addresses.transparentProxyAdmin, initCalldata)
        );
        address contractAddress = deployViaCreate2(bytecode);
        console.log("SharedBridgeProxy deployed at:", contractAddress);
        addresses.bridges.sharedBridgeProxy = contractAddress;
    }
}
