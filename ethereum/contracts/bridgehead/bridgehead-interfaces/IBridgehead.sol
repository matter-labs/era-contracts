// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "../chain-interfaces/IMailbox.sol";

import "./IRegistry.sol";
import "./IRouter.sol";
import "./IBridgeheadGetters.sol";

interface IBridgehead is IMailbox, IBridgeheadGetters, IRegistry, IRouter {}
