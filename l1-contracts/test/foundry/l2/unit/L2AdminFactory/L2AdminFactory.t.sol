// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import { L2AdminFactory } from "contracts/governance/L2AdminFactory.sol";
import { PermanentRestriction } from "contracts/governance/PermanentRestriction.sol";
import { IPermanentRestriction } from "contracts/governance/IPermanentRestriction.sol";

contract L2AdminFactoryTest is Test {
    function testL2AdminFactory() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = makeAddr("required");

        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);

        address[] memory additionalRestrictions = new address[](1);
        additionalRestrictions[0] = makeAddr("additional");

        address[] memory allRestrictions = new address[](2);
        allRestrictions[0] = requiredRestrictions[0];
        allRestrictions[1] = additionalRestrictions[0];


        bytes32 salt = keccak256("salt");

        address admin = factory.deployAdmin(additionalRestrictions, salt);

        // Now, we need to check whether it would be able to accept such an admin
        PermanentRestriction restriction = new PermanentRestriction(
            IBridgehub(address(0)),
            address(factory)
        );

        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(admin)
        }

        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AllowL2Admin(admin);
        restriction.allowL2Admin(
            salt,
            codeHash,
            keccak256(abi.encode(allRestrictions))
        );
    }
}
