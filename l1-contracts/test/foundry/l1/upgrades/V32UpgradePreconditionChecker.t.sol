// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IUpgradePreconditionChecker} from "contracts/upgrades/IUpgradePreconditionChecker.sol";
import {UPGRADE_PRECONDITION_CHECKER_MAGIC} from "contracts/upgrades/UpgradePreconditionCheckerConfig.sol";
import {V32UpgradePreconditionChecker} from "contracts/upgrades/V32UpgradePreconditionChecker.sol";
import {PriorityOpLowerBound} from "contracts/upgrades/PriorityOpLowerBound.sol";
import {IPriorityOpLowerBound} from "contracts/upgrades/IPriorityOpLowerBound.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {
    BaseTokenPreV31TotalSupplyNotSet,
    LowerBoundNotRecorded,
    PriorityQueueNotReady,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {ZKChainNotRegistered} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

// The mocked chain isolates checker logic; the registry is real.
contract V32UpgradePreconditionCheckerTest is Test {
    V32UpgradePreconditionChecker internal checker;
    PriorityOpLowerBound internal registry;
    address internal chain;

    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant TOTAL_PRIORITY_TXS_AT_RECORD_TIME = 7;

    function setUp() public {
        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);
        chain = makeAddr("chainDiamond");

        // Passing baseline; individual tests override one predicate.
        _mockBackfilled(true);
        vm.mockCall(
            chain,
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS_AT_RECORD_TIME)
        );
        registry.lowerBoundPriorityOp(chain);
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME);
    }

    function _mockBackfilled(bool _v) internal {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector), abi.encode(_v));
    }

    function _mockFirstUnprocessedPriorityTx(uint256 _value) internal {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.getFirstUnprocessedPriorityTx.selector), abi.encode(_value));
    }

    function test_constructorRejectsZeroRegistry() public {
        vm.expectRevert(ZeroAddress.selector);
        new V32UpgradePreconditionChecker(IPriorityOpLowerBound(address(0)));
    }

    function test_supportsCheckerMagic() public view {
        assertEq(checker.getSupportsUpgradePreconditionCheckerMagic(), UPGRADE_PRECONDITION_CHECKER_MAGIC);
        assertEq(address(checker.PRIORITY_OP_LOWER_BOUND()), address(registry));
    }

    function test_passesWhenAllPreconditionsHold() public view {
        checker.checkUpgradePreconditions(CHAIN_ID, chain);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 0, "preview must report nothing on a passing chain");
    }

    function test_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        checker.checkUpgradePreconditions(CHAIN_ID, address(0));

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, address(0));
        assertEq(failed.length, 1);
        assertEq(failed[0], ZKChainNotRegistered.selector);
    }

    function test_revertWhen_baseTokenTotalSupplyNotBackfilled() public {
        _mockBackfilled(false);

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        checker.checkUpgradePreconditions(CHAIN_ID, chain);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 1);
        assertEq(failed[0], BaseTokenPreV31TotalSupplyNotSet.selector);
    }

    function test_revertWhen_lowerBoundNotRecorded() public {
        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);

        vm.expectRevert(LowerBoundNotRecorded.selector);
        checker.checkUpgradePreconditions(CHAIN_ID, chain);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 1);
        assertEq(failed[0], LowerBoundNotRecorded.selector);
    }

    function test_revertWhen_priorityOpsBelowLowerBoundNotProcessed() public {
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME - 1);

        vm.expectRevert(PriorityQueueNotReady.selector);
        checker.checkUpgradePreconditions(CHAIN_ID, chain);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 1);
        assertEq(failed[0], PriorityQueueNotReady.selector);
    }

    // Zero is a valid recorded lower bound.
    function test_passesWithZeroLowerBoundAndNoPriorityOpsProcessed() public {
        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector), abi.encode(uint256(0)));
        registry.lowerBoundPriorityOp(chain);
        _mockFirstUnprocessedPriorityTx(0);

        checker.checkUpgradePreconditions(CHAIN_ID, chain);
        assertEq(checker.previewUpgradePreconditions(CHAIN_ID, chain).length, 0);
    }

    // An unrecorded zero bound passes the queue comparison, so only two predicates fail.
    function test_previewCollectsAllFailures() public {
        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);
        _mockBackfilled(false);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 2);
        assertEq(failed[0], BaseTokenPreV31TotalSupplyNotSet.selector);
        assertEq(failed[1], LowerBoundNotRecorded.selector);
    }
}
