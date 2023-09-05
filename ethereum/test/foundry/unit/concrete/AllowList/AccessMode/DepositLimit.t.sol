// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./_AccessMode_Shared.t.sol";

contract DepositLimitTest is AllowListTest {
    address l1token = makeAddr("l1token");

    function test_RevertWhen_NonOwner() public {
        vm.expectRevert(abi.encodePacked("Ownable: caller is not the owner"));
        vm.prank(randomSigner);
        allowList.setDepositLimit(l1token, true, 1000);
    }

    function test_Owner() public {
        vm.prank(owner);
        allowList.setDepositLimit(l1token, true, 1000);

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(
            l1token
        );
        assertEq(
            deposit.depositLimitation,
            true,
            "depositLimitation should be true"
        );
        assertEq(deposit.depositCap, 1000, "depositCap should be 1000");
    }

    function test_UnlimitedToken() public {
        address unlimitedToken = makeAddr("unlimitedToken");

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(
            unlimitedToken
        );

        assertEq(
            deposit.depositLimitation,
            false,
            "depositLimitation should be false"
        );
        assertEq(deposit.depositCap, 0, "depositCap should be 0");
    }
}
