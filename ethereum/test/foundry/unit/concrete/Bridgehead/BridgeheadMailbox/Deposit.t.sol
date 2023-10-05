// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadMailboxTest} from "./_BridgeheadMailbox_Shared.t.sol";

/* solhint-enable max-line-length */

contract DepositTest is BridgeheadMailboxTest {
    function test_RevertWhen_CalledByNonChainContract() public {
        address nonChainContract = makeAddr("nonChainContract");

        vm.expectRevert(abi.encodePacked("12c"));
        vm.startPrank(nonChainContract);
        bridgehead.deposit(chainId);
    }

    function test_SuccessfullIfCalledByChainContract() public {
        address chainContract = bridgehead.getChainContract(chainId);

        vm.startPrank(chainContract);
        bridgehead.deposit(chainId);
    }
}
