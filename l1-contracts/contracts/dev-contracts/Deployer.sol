// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

contract Deployer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBridgehub public immutable bridgehub;

    constructor(IBridgehub _bridgehub) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
    }

    function requestL2Transaction(
        L2TransactionRequestDirect calldata _request
    ) external payable nonReentrant returns (bytes32 canonicalTxHash) {
        address token = bridgehub.baseToken(_request.chainId);
        if (token != ETH_TOKEN_ADDRESS) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), _request.mintValue);
            IERC20(token).approve(address(bridgehub.sharedBridge()), _request.mintValue);
        }
        canonicalTxHash = bridgehub.requestL2TransactionDirect{value: msg.value}(_request);
    }
}
