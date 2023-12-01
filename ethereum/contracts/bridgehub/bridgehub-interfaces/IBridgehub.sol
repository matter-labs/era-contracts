// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "./IBridgehubMailbox.sol";
import "./IBridgehubRegistry.sol";
import "./IBridgehubGetters.sol";
import "./IBridgehubBase.sol";

interface IBridgehub is IBridgehubBase, IBridgehubMailbox, IBridgehubGetters, IBridgehubRegistry {}
