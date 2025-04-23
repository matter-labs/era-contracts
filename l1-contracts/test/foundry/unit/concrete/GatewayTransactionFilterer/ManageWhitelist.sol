// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {AlreadyWhitelisted, NotWhitelisted} from "contracts/common/L1ContractErrors.sol";

contract ManageWhitelistTest is GatewayTransactionFiltererTest {
    function test_GrantingWhitelistToSender() public {
        vm.startPrank(owner);
        transactionFiltererProxy.grantWhitelist(sender);

        assertEq(
            transactionFiltererProxy.whitelistedSenders(sender),
            true,
            "Whitelisting of sender was not successful"
        );

        vm.expectRevert(abi.encodeWithSelector(AlreadyWhitelisted.selector, sender));
        transactionFiltererProxy.grantWhitelist(sender);
    }

    function test_RevokeWhitelistFromSender() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, sender));
        transactionFiltererProxy.revokeWhitelist(sender);

        transactionFiltererProxy.grantWhitelist(sender);
        transactionFiltererProxy.revokeWhitelist(sender);

        assertEq(
            transactionFiltererProxy.whitelistedSenders(sender),
            false,
            "Revoking the sender from whitelist was not successful"
        );
    }
}
