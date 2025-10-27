// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {ChainRegistrationSender} from "contracts/bridgehub/ChainRegistrationSender.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_START, PAUSE_DEPOSITS_TIME_WINDOW_END} from "contracts/common/Config.sol";

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
            if (_depositsPaused(bridgehub, chainsToRegisterOn[i])) {
                console.log(
                    "Info: Deposits are paused on chain:",
                    chainsToRegisterOn[i],
                    ", skipping registration for chain:",
                    _chainId
                );
                continue;
            }
            vm.startBroadcast();
            chainRegistrationSender.registerChain(_chainId, chainsToRegisterOn[i]);
            vm.stopBroadcast();
        }
    }

    function _depositsPaused(IBridgehubBase bridgehub, uint256 chainToRegisterOn) internal view returns (bool) {
        address zkChain = bridgehub.getZKChain(chainToRegisterOn);
        bytes32 _pausedDepositsTimestamp = vm.load(zkChain, bytes32(uint256(62)));

        uint256 timestamp = uint256(_pausedDepositsTimestamp);
        return
            timestamp + PAUSE_DEPOSITS_TIME_WINDOW_START <= block.timestamp &&
            block.timestamp < timestamp + PAUSE_DEPOSITS_TIME_WINDOW_END;
    }
}
