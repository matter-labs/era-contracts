// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/chain-deps/facets/Base.sol";

contract DummyAdminFacet is ZkSyncStateTransitionBase {
    function dummySetValidator(address _validator) external {
        s.validators[_validator] = true;
    }
}
