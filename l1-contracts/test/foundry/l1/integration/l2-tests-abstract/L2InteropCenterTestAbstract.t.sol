// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {L2InteropLibraryBasicTestAbstract} from "./L2InteropLibraryBasicTestAbstract.t.sol";
import {L2InteropNativeTokenDifferentBaseTestAbstract} from "./L2InteropNativeTokenDifferentBaseTestAbstract.t.sol";
import {L2InteropNativeTokenSimpleTestAbstract} from "./L2InteropNativeTokenSimpleTestAbstract.t.sol";
import {L2InteropMessageHandlerTestAbstract} from "./L2InteropMessageHandlerTestAbstract.t.sol";

abstract contract L2InteropCenterTestAbstract is
    L2InteropLibraryBasicTestAbstract,
    L2InteropNativeTokenDifferentBaseTestAbstract,
    L2InteropNativeTokenSimpleTestAbstract,
    L2InteropMessageHandlerTestAbstract
{
    // This contract combines all the split test abstracts to maintain backward compatibility
    // with existing test files that inherit from L2InteropCenterTestAbstract
}
