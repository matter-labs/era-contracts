// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {L2InteropExecuteBundleTestAbstract} from "./L2InteropExecuteBundleTestAbstract.t.sol";
import {L2InteropUnbundleTestAbstract} from "./L2InteropUnbundleTestAbstract.t.sol";

abstract contract L2InteropMessageHandlerTestAbstract is
    L2InteropExecuteBundleTestAbstract,
    L2InteropUnbundleTestAbstract
{
    // This contract combines execute and unbundle tests
}
