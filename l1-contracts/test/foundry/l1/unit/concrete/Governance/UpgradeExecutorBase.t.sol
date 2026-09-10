// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutorBase} from "contracts/governance/UpgradeExecutorBase.sol";
import {Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

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
///      owner-gated `forward` + `receive`) without any domain entrypoints.
contract TestUpgradeExecutor is UpgradeExecutorBase {
    constructor(address _initialOwner) UpgradeExecutorBase(_initialOwner) {}
}

/// @notice Tests the shared authority base under its ONE-role model: ownership, the owner-gated
///         raw-call escape hatch `forward` (a plain call, no delegatecall) and `receive`.
/// @dev There is deliberately no second "emergency board" role to test: routine and emergency
///      governance both reach the executor as the same `msg.sender` (the ProtocolUpgradeHandler
///      performs the calls for either route), so an on-chain gate on a board address could not
///      tell them apart and would have left `forward` dead. What gates raw calls is the owner's
///      own governance process, not this contract.
contract UpgradeExecutorBaseTest is Test {
    event CallForwarded(address indexed target, uint256 value, bytes data);

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    TestUpgradeExecutor internal executor;
    OwnedTarget internal target;

    function setUp() public {
        executor = new TestUpgradeExecutor(governance);
        target = new OwnedTarget(address(executor));
    }

    function _setValueCall(OwnedTarget _target, uint256 _value, uint256 _ethValue) internal pure returns (Call memory) {
        return Call({target: address(_target), value: _ethValue, data: abi.encodeCall(OwnedTarget.setValue, (_value))});
    }

    /*//////////////////////////////////////////////////////////////
                              constructor
    //////////////////////////////////////////////////////////////*/

    function test_constructorSetsOwner() public view {
        assertEq(executor.owner(), governance);
        assertEq(executor.pendingOwner(), address(0));
    }

    function test_revertWhen_constructorZeroOwner() public {
        // A zero owner would permanently disable every entrypoint, the escape hatch included:
        // Ownable2Step cannot hand ownership out of address(0).
        vm.expectRevert(ZeroAddress.selector);
        new TestUpgradeExecutor(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               forward
    //////////////////////////////////////////////////////////////*/

    function test_successfulForward_multipleCallsWithValue() public {
        vm.deal(address(executor), 1 ether);

        Call[] memory calls = new Call[](2);
        calls[0] = _setValueCall(target, 3, 0.25 ether);
        calls[1] = _setValueCall(target, 4, 0);

        vm.expectEmit(true, true, true, true, address(executor));
        emit CallForwarded(address(target), 0.25 ether, calls[0].data);
        vm.expectEmit(true, true, true, true, address(executor));
        emit CallForwarded(address(target), 0, calls[1].data);

        vm.prank(governance);
        executor.forward(calls);

        // Calls execute in order: the second write wins, the value of the first arrived.
        assertEq(target.value(), 4);
        assertEq(target.received(), 0.25 ether);
        assertEq(address(executor).balance, 0.75 ether);
    }

    function test_revertWhen_forwardCalledByStranger() public {
        Call[] memory calls = new Call[](1);
        calls[0] = _setValueCall(target, 1, 0);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        executor.forward(calls);

        assertEq(target.value(), 0, "a refused forward must not reach the target");
    }

    function test_revertWhen_forwardedCallReverts() public {
        // The target is owner-gated on the executor, so a call forwarded to a target the
        // executor does NOT own must bubble the target's own revert data unchanged.
        OwnedTarget foreignTarget = new OwnedTarget(makeAddr("someoneElse"));

        Call[] memory calls = new Call[](1);
        calls[0] = _setValueCall(foreignTarget, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(executor)));
        vm.prank(governance);
        executor.forward(calls);
    }

    function test_revertWhen_aLaterCallFailsTheWholeBatchRollsBack() public {
        // `forward` reverts on the first failure, so a batch is all-or-nothing: the successful
        // first call must not survive the second call's revert.
        OwnedTarget foreignTarget = new OwnedTarget(makeAddr("someoneElse"));

        Call[] memory calls = new Call[](2);
        calls[0] = _setValueCall(target, 3, 0);
        calls[1] = _setValueCall(foreignTarget, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(executor)));
        vm.prank(governance);
        executor.forward(calls);

        assertEq(target.value(), 0, "the first call must be rolled back with the batch");
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

    function test_forwardAuthorityFollowsOwnership() public {
        // One role: the escape hatch is not a separate capability, so it moves with ownership —
        // the departed owner loses it and the new owner gains it, at acceptance and not before.
        address newGovernance = makeAddr("newGovernance");
        Call[] memory calls = new Call[](1);
        calls[0] = _setValueCall(target, 7, 0);

        vm.prank(governance);
        executor.transferOwnership(newGovernance);

        // A pending owner holds nothing yet.
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(newGovernance);
        executor.forward(calls);

        vm.prank(newGovernance);
        executor.acceptOwnership();

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(governance);
        executor.forward(calls);

        vm.expectEmit(true, true, true, true, address(executor));
        emit CallForwarded(address(target), 0, calls[0].data);
        vm.prank(newGovernance);
        executor.forward(calls);
        assertEq(target.value(), 7);
    }
}
