// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "./IBridgehubMailbox.sol";
import "./IRegistry.sol";
import "./IBridgehubGetters.sol";
import "./IBridgehubAdmin.sol";

interface IBridgehub is IBridgehubMailbox, IBridgehubGetters, IRegistry, IBridgehubAdmin {}
