// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2AdminFactory} from "contracts/governance/L2AdminFactory.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {DummyRestriction} from "contracts/dev-contracts/DummyRestriction.sol";
import {NotARestriction} from "contracts/common/L1ContractErrors.sol";

contract L2AdminFactoryTest is Test {
    address validRestriction1;
    address validRestriction2;

    address invalidRestriction;

    function setUp() public {
        validRestriction1 = address(new DummyRestriction(true));
        validRestriction2 = address(new DummyRestriction(true));

        invalidRestriction = address(new DummyRestriction(false));
    }

    function test_invalidInitialRestriction() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = invalidRestriction;

        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, address(invalidRestriction)));
        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);
    }

    function test_invalidAdditionalRestriction() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = validRestriction1;

        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);

        address[] memory additionalRestrictions = new address[](1);
        additionalRestrictions[0] = invalidRestriction;

        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, address(invalidRestriction)));
        factory.deployAdmin(additionalRestrictions);
    }

    function testL2AdminFactory() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = validRestriction1;

        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);

        address[] memory additionalRestrictions = new address[](1);
        additionalRestrictions[0] = validRestriction2;

        address[] memory allRestrictions = new address[](2);
        allRestrictions[0] = requiredRestrictions[0];
        allRestrictions[1] = additionalRestrictions[0];

        address admin = factory.deployAdmin(additionalRestrictions);

        // Now, we need to check whether it would be able to accept such an admin
        PermanentRestriction restriction = new PermanentRestriction(IBridgehub(address(0)), address(factory));

        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(admin)
        }

        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AllowL2Admin(admin);
        restriction.allowL2Admin(uint256(0));
    }
}
