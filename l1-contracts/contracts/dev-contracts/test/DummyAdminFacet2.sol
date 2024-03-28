// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ZkSyncStateTransitionBase} from "../../state-transition/chain-deps/facets/ZkSyncStateTransitionBase.sol";

contract DummyAdminFacet2 is ZkSyncStateTransitionBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function getName() external pure returns (string memory) {
        return "DummyAdminFacet";
    }

    function dummySetValidator(address _validator) external {
        s.validators[_validator] = true;
    }

    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external {
        Diamond.diamondCut(_diamondCut);
    }
}
