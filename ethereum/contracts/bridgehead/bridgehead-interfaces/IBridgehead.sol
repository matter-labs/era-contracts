// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "../chain-interfaces/IBridgeheadMailbox.sol";

import "./IRegistry.sol";
import "./IRouter.sol";
import "./IBridgeheadGetters.sol";

interface IBridgehead is IBridgeheadMailbox, IBridgeheadGetters, IRegistry, IRouter {
    function deposit(uint256 _chainId) external payable;

    function withdrawFunds(
        uint256 _chainId,
        address _to,
        uint256 _amount
    ) external;
}
