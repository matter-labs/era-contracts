// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/Messaging.sol";

import "./IBridgehubMailbox.sol";
import "./IBridgehubRegistry.sol";
import "./IBridgehubGetters.sol";

interface IBridgehub is IBridgehubMailbox, IBridgehubGetters, IBridgehubRegistry {
    function getName() external view returns (string memory);
}
