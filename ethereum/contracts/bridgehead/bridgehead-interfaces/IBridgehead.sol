// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "./IBridgeheadMailbox.sol";
import "./IRegistry.sol";
import "./IBridgeheadGetters.sol";

interface IBridgehead is IBridgeheadMailbox, IBridgeheadGetters, IRegistry, IBridgeheadAdmin {
}
