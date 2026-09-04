// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    IUpgradePreconditionChecker,
    UPGRADE_PRECONDITION_CHECKER_MAGIC
} from "contracts/upgrades/IUpgradePreconditionChecker.sol";
import {V33UpgradePreconditionChecker} from "contracts/upgrades/V33UpgradePreconditionChecker.sol";
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

/// @notice Unit tests for the scheduling-time counterpart of `V32UpgradeZKsyncOS`'s execution-time
/// prerequisite triple. The chain is a mocked address (same isolation as `PriorityOpLowerBoundTest`):
/// the checker only reads two `IGetters` views on it, and the registry under test is real.
contract V33UpgradePreconditionCheckerTest is Test {
    V33UpgradePreconditionChecker internal checker;
    PriorityOpLowerBound internal registry;
    address internal chain;

    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant TOTAL_PRIORITY_TXS_AT_RECORD_TIME = 7;

    function setUp() public {
        registry = new PriorityOpLowerBound();
        checker = new V33UpgradePreconditionChecker(registry);
        chain = makeAddr("chainDiamond");

        // The default shape: backfill flag set, bound recorded, priority ops processed through it.
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
        new V33UpgradePreconditionChecker(IPriorityOpLowerBound(address(0)));
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
        // Fresh registry and checker: nothing recorded for the chain.
        registry = new PriorityOpLowerBound();
        checker = new V33UpgradePreconditionChecker(registry);

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

    /// @notice A chain created on v31 records a legitimate zero bound and passes with zero ops
    /// processed (0 >= 0) — mirrors `V32UpgradeZKsyncOSTest`'s zero-bound case.
    function test_passesWithZeroLowerBoundAndNoPriorityOpsProcessed() public {
        registry = new PriorityOpLowerBound();
        checker = new V33UpgradePreconditionChecker(registry);
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector), abi.encode(uint256(0)));
        registry.lowerBoundPriorityOp(chain);
        _mockFirstUnprocessedPriorityTx(0);

        checker.checkUpgradePreconditions(CHAIN_ID, chain);
        assertEq(checker.previewUpgradePreconditions(CHAIN_ID, chain).length, 0);
    }

    /// @notice The preview collects the failed preconditions, while the reverting check stops at
    /// the first one. An unrecorded bound reads as zero and trivially passes the queue check, so
    /// `LowerBoundNotRecorded` and `PriorityQueueNotReady` never appear together (max 2 entries).
    function test_previewCollectsAllFailures() public {
        registry = new PriorityOpLowerBound();
        checker = new V33UpgradePreconditionChecker(registry);
        _mockBackfilled(false);

        bytes4[] memory failed = checker.previewUpgradePreconditions(CHAIN_ID, chain);
        assertEq(failed.length, 2);
        assertEq(failed[0], BaseTokenPreV31TotalSupplyNotSet.selector);
        assertEq(failed[1], LowerBoundNotRecorded.selector);
    }
}
