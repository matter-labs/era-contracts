// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBase} from "../../state-transition/chain-deps/facets/ZKChainBase.sol";

contract DummyAdminFacet is ZKChainBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function getName() external pure returns (string memory) {
        return "DummyAdminFacet";
    }

    function dummySetValidator(address _validator) external {
        s.validators[_validator] = true;
    }
}
