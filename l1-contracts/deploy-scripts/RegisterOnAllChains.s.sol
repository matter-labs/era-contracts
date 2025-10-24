// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {ChainRegistrationSender} from "contracts/bridgehub/ChainRegistrationSender.sol";

contract RegisterOnAllChainsScript is Script {
    function registerOnOtherChains(address _bridgehub, uint256 _chainId) public {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        uint256[] memory chainsToRegisterOn = bridgehub.getAllZKChainChainIDs();
        ChainRegistrationSender chainRegistrationSender = ChainRegistrationSender(bridgehub.chainRegistrationSender());

        for (uint256 i = 0; i < chainsToRegisterOn.length; i++) {
            if (chainRegistrationSender.chainRegisteredOnChain(chainsToRegisterOn[i], _chainId)) {
                continue;
            }
            vm.startBroadcast();
            chainRegistrationSender.registerChain(chainsToRegisterOn[i], _chainId);
            vm.stopBroadcast();
        }
        for (uint256 i = 0; i < chainsToRegisterOn.length; i++) {
            if (
                chainRegistrationSender.chainRegisteredOnChain(_chainId, chainsToRegisterOn[i]) ||
                chainsToRegisterOn[i] == _chainId
            ) {
                continue;
            }
            vm.startBroadcast();
            chainRegistrationSender.registerChain(_chainId, chainsToRegisterOn[i]);
            vm.stopBroadcast();
        }
    }
}
