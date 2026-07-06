// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {IUpgradeExecutor} from "contracts/governance/IUpgradeExecutor.sol";
import {AddressHasNoCode, ModuleAlteredOwnership, Unauthorized} from "contracts/common/L1ContractErrors.sol";

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

/// @dev A stateless orchestrator module: acts with the executor's identity via delegatecall.
contract GoodModule {
    function run(address _target, uint256 _value) external returns (uint256) {
        OwnedTarget(_target).setValue(_value);
        return _value + 1;
    }
}

contract RevertingModule {
    error ModuleFailed(uint256 code);

    function run() external pure {
        revert ModuleFailed(42);
    }
}

/// @dev A malicious/buggy module that overwrites the executor's owner slot (slot 0 of OZ Ownable).
contract OwnerClobberModule {
    function run() external {
        assembly {
            sstore(0, 0xdead)
        }
    }
}

/// @dev A malicious/buggy module that overwrites the executor's pendingOwner slot
///      (slot 1 of OZ Ownable2Step).
contract PendingOwnerClobberModule {
    function run() external {
        assembly {
            sstore(1, 0xdead)
        }
    }
}

contract UpgradeExecutorTest is Test {
    event UpgradeModuleExecuted(address indexed module, bytes data);
    event CallForwarded(address indexed target, uint256 value, bytes data);

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    UpgradeExecutor internal executor;
    OwnedTarget internal target;
    GoodModule internal goodModule;

    function setUp() public {
        executor = new UpgradeExecutor(governance);
        target = new OwnedTarget(address(executor));
        goodModule = new GoodModule();
    }

    /*//////////////////////////////////////////////////////////////
                              constructor
    //////////////////////////////////////////////////////////////*/

    function test_constructorSetsOwner() public view {
        assertEq(executor.owner(), governance);
        assertEq(executor.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               execute
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_executeCalledByNonOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        executor.execute(address(goodModule), abi.encodeCall(GoodModule.run, (address(target), 1)));
    }

    function test_revertWhen_executeModuleHasNoCode() public {
        address emptyModule = makeAddr("emptyModule");

        vm.expectRevert(abi.encodeWithSelector(AddressHasNoCode.selector, emptyModule));
        vm.prank(governance);
        executor.execute(emptyModule, hex"");
    }

    function test_successfulExecute_actsWithExecutorIdentity() public {
        bytes memory data = abi.encodeCall(GoodModule.run, (address(target), 7));

        vm.expectEmit(true, true, true, true, address(executor));
        emit UpgradeModuleExecuted(address(goodModule), data);

        vm.prank(governance);
        bytes memory returnData = executor.execute(address(goodModule), data);

        // The module ran with the executor's identity: the owner-gated target accepted the call.
        assertEq(target.value(), 7);
        // The module's return data is bubbled to the caller.
        assertEq(abi.decode(returnData, (uint256)), 8);
        // Ownership is untouched by a well-behaved module.
        assertEq(executor.owner(), governance);
    }

    function test_revertWhen_executeModuleReverts() public {
        RevertingModule revertingModule = new RevertingModule();

        vm.expectRevert(abi.encodeWithSelector(RevertingModule.ModuleFailed.selector, 42));
        vm.prank(governance);
        executor.execute(address(revertingModule), abi.encodeCall(RevertingModule.run, ()));
    }

    function test_revertWhen_executeModuleClobbersOwner() public {
        OwnerClobberModule clobberModule = new OwnerClobberModule();

        vm.expectRevert(ModuleAlteredOwnership.selector);
        vm.prank(governance);
        executor.execute(address(clobberModule), abi.encodeCall(OwnerClobberModule.run, ()));

        // The revert rolled the write back.
        assertEq(executor.owner(), governance);
    }

    function test_revertWhen_executeModuleClobbersPendingOwner() public {
        PendingOwnerClobberModule clobberModule = new PendingOwnerClobberModule();

        vm.expectRevert(ModuleAlteredOwnership.selector);
        vm.prank(governance);
        executor.execute(address(clobberModule), abi.encodeCall(PendingOwnerClobberModule.run, ()));

        assertEq(executor.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               forward
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_forwardCalledByNonOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
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

        vm.prank(governance);
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
        vm.prank(governance);
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
}
