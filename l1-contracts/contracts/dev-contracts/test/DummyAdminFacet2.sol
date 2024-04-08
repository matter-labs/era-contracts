// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ZkSyncHyperchainBase} from "../../state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";

contract DummyAdminFacet2 is ZkSyncHyperchainBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function getName() external pure returns (string memory) {
        return "DummyAdminFacet2";
    }

    function executeUpgrade2(Diamond.DiamondCutData calldata _diamondCut) external {
        Diamond.diamondCut(_diamondCut);
    }
}
