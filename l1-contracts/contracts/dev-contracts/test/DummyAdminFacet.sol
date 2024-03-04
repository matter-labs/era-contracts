// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/chain-deps/facets/ZkSyncStateTransitionBase.sol";

contract DummyAdminFacet is ZkSyncStateTransitionBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function dummySetValidator(address _validator) external {
        s.validators[_validator] = true;
    }
}
