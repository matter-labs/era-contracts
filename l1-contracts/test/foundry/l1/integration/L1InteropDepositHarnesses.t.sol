// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BridgehubInvariantTests_1} from "./BridgehubInvariantTests_1.t.sol";
import {BoundedBridgehubInvariantTests_2} from "./BridgehubInvariantTests_2.t.sol";

// Exercise the migrated deposit handlers without enabling the unrelated, dormant withdrawal invariants (EVM-1391).
contract L1InteropUnboundedDepositHarnessTest is BridgehubInvariantTests_1 {
    function setUp() public {
        prepare();
    }
    function test_depositFundingMatrix() public {
        for (uint256 chain = 0; chain < zkChainIds.length; ++chain) {
            depositEthToBridgeSuccess(0, chain, 1 ether);
            depositERC20ToBridgeSuccess(0, chain, 0, 1 ether);
            depositERC20ToBridgeSuccess(0, chain, 1, 1 ether);
        }
        assertGt(tokenSumDeposit[tokens[0]], 0);
    }
}

contract L1InteropBoundedDepositHarnessTest is BoundedBridgehubInvariantTests_2 {
    function setUp() public {
        prepare();
    }
    function test_depositFundingMatrix() public {
        for (uint256 chain = 0; chain < zkChainIds.length; ++chain) {
            depositEthSuccess(0, chain, 1 ether);
            depositERC20Success(0, chain, 0, 1 ether);
            depositERC20Success(0, chain, 1, 1 ether);
        }
        assertGt(tokenSumDeposit[tokens[0]], 0);
    }
}
