// SPDX-License-Identifier: MIT

import {CommitterFacet} from "../../state-transition/chain-deps/facets/Committer.sol";

pragma solidity 0.8.28;

contract TestCommitter is CommitterFacet {
    constructor() CommitterFacet(block.chainid) {}

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
