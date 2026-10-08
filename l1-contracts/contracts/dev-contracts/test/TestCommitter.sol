// SPDX-License-Identifier: MIT

import {CommitterFacet} from "../../state-transition/chain-deps/facets/Committer.sol";
import {IInteropFeeManager} from "../../core/interop-fee/IInteropFeeManager.sol";

pragma solidity 0.8.28;

contract TestCommitter is CommitterFacet {
    constructor(IInteropFeeManager _interopFeeManager) CommitterFacet(block.chainid, _interopFeeManager) {}

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
