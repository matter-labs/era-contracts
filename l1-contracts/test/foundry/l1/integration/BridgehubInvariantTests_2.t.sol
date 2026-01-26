// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {
    IL1Bridgehub,
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {BridgehubInvariantTests_1} from "test/foundry/l1/integration/BridgehubInvariantTests_1.t.sol";

contract BoundedBridgehubInvariantTests_2 is BridgehubInvariantTests_1 {
    function depositEthSuccess(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 l2Value) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        emit log_string("DEPOSIT ETH");
        super.depositEthToBridgeSuccess(userIndexSeed, chainIndexSeed, l2Value);
    }

    function depositERC20Success(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 tokenIndexSeed,
        uint256 l2Value
    ) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        emit log_string("DEPOSIT ERC20");
        super.depositERC20ToBridgeSuccess(userIndexSeed, chainIndexSeed, tokenIndexSeed, l2Value);
    }

    function withdrawERC20Success(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 amountToWithdraw) public {
        uint64 MAX = (2 ** 32 - 1) + 0.1 ether;
        uint256 amountToWithdraw = bound(amountToWithdraw, 0.1 ether, MAX);

        emit log_string("WITHDRAW ERC20");
        super.withdrawSuccess(userIndexSeed, chainIndexSeed, amountToWithdraw);
    }

    // add this to be excluded from coverage report
    function testBoundedBridgehubInvariant() internal {}
}

contract InvariantTesterZKChains is Test {
    BoundedBridgehubInvariantTests_2 tests;

    function setUp() public {
        tests = new BoundedBridgehubInvariantTests_2();
        // tests.prepare();
    }

    // // Check whether the sum of ETH deposits from tests, updated on each deposit and withdrawal,
    // // equals the balance of L1Shared bridge.
    // function invariant_ETHbalanceStaysEqual() public {
    //     require(1==1);
    // }

    // add this to be excluded from coverage report
    function test() internal {}
}
