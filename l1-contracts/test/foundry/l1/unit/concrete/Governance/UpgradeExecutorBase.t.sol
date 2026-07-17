// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutorBase} from "contracts/governance/UpgradeExecutorBase.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @dev A contract whose owner-gated function stands in for the owner-gated entrypoints
///      (CTM, ProxyAdmin, ...) whose ownership the executor holds in production.
contract OwnedTarget {
    address public immutable OWNER;
    uint256 public value;
    uint256 public received;

    constructor(address _owner) {
        OWNER = _owner;
    }

    function setValue(uint256 _value) external payable {
        if (msg.sender != OWNER) {
            revert Unauthorized(msg.sender);
        }
        value = _value;
        received += msg.value;
    }
}

/// @dev Minimal concrete executor: exercises the shared `UpgradeExecutorBase` (ownership +
///      break-glass `forward` + `receive`) without any domain entrypoints.
contract TestUpgradeExecutor is UpgradeExecutorBase {
    constructor(address _initialOwner, address _breakGlass) UpgradeExecutorBase(_initialOwner, _breakGlass) {}
}

/// @notice Tests the shared authority base: ownership, the SEPARATELY GOVERNED break-glass
///         `forward` hatch (the only arbitrary authority — a plain call, no delegatecall),
///         and `receive`.
contract UpgradeExecutorBaseTest is Test {
    event CallForwarded(address indexed target, uint256 value, bytes data);

    address internal governance = makeAddr("governance");
    address internal breakGlass = makeAddr("breakGlass");
    address internal stranger = makeAddr("stranger");

    TestUpgradeExecutor internal executor;
    OwnedTarget internal target;

    function setUp() public {
        executor = new TestUpgradeExecutor(governance, breakGlass);
        target = new OwnedTarget(address(executor));
    }

    /*//////////////////////////////////////////////////////////////
                              constructor
    //////////////////////////////////////////////////////////////*/

    function test_constructorSetsOwnerAndBreakGlass() public view {
        assertEq(executor.owner(), governance);
        assertEq(executor.pendingOwner(), address(0));
        assertEq(executor.breakGlassGovernor(), breakGlass);
    }

    /*//////////////////////////////////////////////////////////////
                               forward
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_forwardCalledByNonBreakGlass() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        vm.prank(stranger);
        executor.forward(new Call[](0));
    }

    function test_revertWhen_forwardCalledByOwner() public {
        // Break-glass is a SEPARATE authority: the owner drives only the fixed domain
        // entrypoints and cannot bypass their invariants through raw calls.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        vm.prank(governance);
        executor.forward(new Call[](0));
    }

    function test_successfulForward_multipleCallsWithValue() public {
        vm.deal(address(executor), 1 ether);

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(target), value: 0.25 ether, data: abi.encodeCall(OwnedTarget.setValue, (3))});
        calls[1] = Call({target: address(target), value: 0, data: abi.encodeCall(OwnedTarget.setValue, (4))});

        vm.expectEmit(true, true, true, true, address(executor));
        emit CallForwarded(address(target), 0.25 ether, calls[0].data);
        vm.expectEmit(true, true, true, true, address(executor));
        emit CallForwarded(address(target), 0, calls[1].data);

        vm.prank(breakGlass);
        executor.forward(calls);

        // Calls execute in order: the second write wins, the value of the first arrived.
        assertEq(target.value(), 4);
        assertEq(target.received(), 0.25 ether);
        assertEq(address(executor).balance, 0.75 ether);
    }

    function test_revertWhen_forwardedCallReverts() public {
        // The target is owner-gated on the executor, so a call forwarded to a target the
        // executor does NOT own must bubble the target's revert.
        OwnedTarget foreignTarget = new OwnedTarget(makeAddr("someoneElse"));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(foreignTarget), value: 0, data: abi.encodeCall(OwnedTarget.setValue, (1))});

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(executor)));
        vm.prank(breakGlass);
        executor.forward(calls);
    }

    /*//////////////////////////////////////////////////////////////
                               receive
    //////////////////////////////////////////////////////////////*/

    function test_receiveEth() public {
        vm.deal(governance, 1 ether);

        vm.prank(governance);
        (bool success, ) = address(executor).call{value: 0.5 ether}("");

        assertTrue(success);
        assertEq(address(executor).balance, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          ownership handover
    //////////////////////////////////////////////////////////////*/

    function test_ownershipHandoverIsTwoStep() public {
        address newGovernance = makeAddr("newGovernance");

        vm.prank(governance);
        executor.transferOwnership(newGovernance);

        // Nothing changes until acceptance.
        assertEq(executor.owner(), governance);
        assertEq(executor.pendingOwner(), newGovernance);

        vm.prank(newGovernance);
        executor.acceptOwnership();

        assertEq(executor.owner(), newGovernance);
        assertEq(executor.pendingOwner(), address(0));
    }

    function test_breakGlassHandoverIsTwoStep() public {
        address council = makeAddr("securityCouncil");

        vm.prank(breakGlass);
        executor.transferBreakGlassGovernor(council);

        // Nothing changes until acceptance; the pending holder cannot forward yet.
        assertEq(executor.breakGlassGovernor(), breakGlass);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, council));
        vm.prank(council);
        executor.forward(new Call[](0));

        vm.prank(council);
        executor.acceptBreakGlassGovernor();
        assertEq(executor.breakGlassGovernor(), council);
        assertEq(executor.pendingBreakGlassGovernor(), address(0));

        // The old holder lost the capability.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, breakGlass));
        vm.prank(breakGlass);
        executor.forward(new Call[](0));
    }

    function test_revertWhen_breakGlassTransferByNonHolder() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        vm.prank(governance);
        executor.transferBreakGlassGovernor(governance);
    }
}
