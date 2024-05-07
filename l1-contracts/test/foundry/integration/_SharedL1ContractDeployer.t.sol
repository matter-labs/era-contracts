// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployL1Script} from "../../../scripts-rs/script/DeployL1.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

contract L1ContractDeployer is Test {
    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    function deployL1Contracts() internal {
        DeployL1Script l1Script = new DeployL1Script();
        l1Script.run();

        bridgehubOwnerAddress = l1Script.getBridgehubOwnerAddress();
        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);
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
}
