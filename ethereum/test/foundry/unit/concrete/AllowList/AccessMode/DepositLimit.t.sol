// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Vm} from "forge-std/Test.sol";
import {AccessModeTest} from "./_AccessMode_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract DepositLimitTest is AccessModeTest {
    address private l1token = makeAddr("l1token");

    function test_RevertWhen_NonOwner() public {
        vm.expectRevert(abi.encodePacked("Ownable: caller is not the owner"));
        vm.prank(randomSigner);
        allowList.setDepositLimit(l1token, true, 1000);
    }

    function test_Owner() public {
        vm.prank(owner);
        allowList.setDepositLimit(l1token, true, 1000);

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(l1token);
        assertEq(deposit.depositLimitation, true, "depositLimitation should be true");
        assertEq(deposit.depositCap, 1000, "depositCap should be 1000");
    }

    function test_UnlimitedToken() public {
        address unlimitedToken = makeAddr("unlimitedToken");

        IAllowList.Deposit memory deposit = allowList.getTokenDepositLimitData(unlimitedToken);

        assertEq(deposit.depositLimitation, false, "depositLimitation should be false");
        assertEq(deposit.depositCap, 0, "depositCap should be 0");
    }

    function test_UpdateDepositLimitEvent() public {
        vm.startPrank(owner);

        vm.recordLogs();
        allowList.setDepositLimit(l1token, true, 1000);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics.length, 2);
        assertEq(
            entries[0].topics[0],
            keccak256("UpdateDepositLimit(address,bool,uint256)"),
            "received event should be correct"
        );
        assertEq(
            entries[0].topics[1],
            bytes32(uint256(uint160(l1token))),
            "received l1Token address should be correct"
        );
        assertEq(
            entries[0].data,
            abi.encode(true, 1000),
            "received depositLimitation and depositCap should be correct"
        );
    }
}
