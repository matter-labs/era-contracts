// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployL1Script} from "../../../scripts-rs/script/DeployL1.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";

contract L1ContractDeployer is Test {
    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    address sharedBridgeProxyAddress;
    L1SharedBridge sharedBridge;

    function deployL1Contracts() internal {
        DeployL1Script l1Script = new DeployL1Script();
        l1Script.run();

        bridgehubOwnerAddress = l1Script.getBridgehubOwnerAddress();
        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        sharedBridgeProxyAddress = l1Script.getSharedBridgeProxyAddress();
        sharedBridge = L1SharedBridge(sharedBridgeProxyAddress);
    }

    function registerNewToken(address _tokenAddress) internal {
        if (!bridgeHub.tokenIsRegistered(_tokenAddress)) {
            vm.prank(bridgehubOwnerAddress);
            bridgeHub.addToken(_tokenAddress);
        }
    }

    function registerNewTokens(address[] memory _tokens) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            registerNewToken(_tokens[i]);
        }
    }

    function registerL2SharedBridge(uint256 _chainId, address _l2SharedBridge) internal {
        vm.prank(bridgehubOwnerAddress);
        sharedBridge.initializeChainGovernance(_chainId, _l2SharedBridge);
    }
}
