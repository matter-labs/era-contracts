// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

/* solhint-enable max-line-length */

contract DepositTest is BridgehubMailboxTest {
    function test_RevertWhen_CalledByNonChainContract() public {
        address nonChainContract = makeAddr("nonChainContract");

        vm.expectRevert(abi.encodePacked("12c"));
        vm.startPrank(nonChainContract);
        bridgehub.deposit(chainId);
    }

    function test_SuccessfullIfCalledByChainContract() public {
        address chainContract = bridgehub.getChainContract(chainId);

        vm.startPrank(chainContract);
        bridgehub.deposit(chainId);
    }
}
