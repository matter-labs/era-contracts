// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {NoCallsProvided, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock contract to test setTokenMultiplier functionality
contract MockChainContract {
    uint128 public lastNominator;
    uint128 public lastDenominator;
    bool public tokenMultiplierCalled;

    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external {
        lastNominator = _nominator;
        lastDenominator = _denominator;
        tokenMultiplierCalled = true;
    }
}

/// @notice Mock contract that reverts on call
contract MockRevertingContract {
    error MockError();

    fallback() external payable {
        revert MockError();
    }
}

/// @notice Unit tests for ChainAdminOwnable contract
contract ChainAdminOwnableTest is Test {
    ChainAdminOwnable internal chainAdminOwnable;
    MockChainContract internal mockChainContract;
    MockRevertingContract internal mockRevertingContract;

    address internal owner;
    address internal tokenMultiplierSetter;
    address internal randomUser;

    event UpdateUpgradeTimestamp(uint256 indexed _protocolVersion, uint256 _upgradeTimestamp);
    event CallExecuted(IChainAdminOwnable.Call _call, bool _success, bytes _returnData);
    event NewTokenMultiplierSetter(address _oldTokenMultiplierSetter, address _newTokenMultiplierSetter);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        owner = makeAddr("owner");
        tokenMultiplierSetter = makeAddr("tokenMultiplierSetter");
        randomUser = makeAddr("randomUser");

        chainAdminOwnable = new ChainAdminOwnable(owner, tokenMultiplierSetter);
        mockChainContract = new MockChainContract();
        mockRevertingContract = new MockRevertingContract();
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(chainAdminOwnable.owner(), owner);
    }

    function test_constructor_setsTokenMultiplierSetter() public view {
        assertEq(chainAdminOwnable.tokenMultiplierSetter(), tokenMultiplierSetter);
    }

    function test_constructor_revertsOnZeroAddressOwner() public {
        vm.expectRevert(ZeroAddress.selector);
        new ChainAdminOwnable(address(0), tokenMultiplierSetter);
    }

    function test_constructor_allowsZeroTokenMultiplierSetter() public {
        ChainAdminOwnable adminWithZeroSetter = new ChainAdminOwnable(owner, address(0));
        assertEq(adminWithZeroSetter.tokenMultiplierSetter(), address(0));
    }

    function test_constructor_emitsNewTokenMultiplierSetterEvent() public {
        vm.expectEmit(true, true, false, true);
        emit NewTokenMultiplierSetter(address(0), tokenMultiplierSetter);
        new ChainAdminOwnable(owner, tokenMultiplierSetter);
    }

    // ============ setTokenMultiplierSetter Tests ============

    function test_setTokenMultiplierSetter_updatesValue() public {
        address newSetter = makeAddr("newSetter");

        vm.prank(owner);
        chainAdminOwnable.setTokenMultiplierSetter(newSetter);

        assertEq(chainAdminOwnable.tokenMultiplierSetter(), newSetter);
    }

    function test_setTokenMultiplierSetter_emitsEvent() public {
        address newSetter = makeAddr("newSetter");

        vm.expectEmit(true, true, false, true);
        emit NewTokenMultiplierSetter(tokenMultiplierSetter, newSetter);

        vm.prank(owner);
        chainAdminOwnable.setTokenMultiplierSetter(newSetter);
    }

    function test_setTokenMultiplierSetter_revertsIfNotOwner() public {
        address newSetter = makeAddr("newSetter");

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainAdminOwnable.setTokenMultiplierSetter(newSetter);
    }

    function test_setTokenMultiplierSetter_allowsZeroAddress() public {
        vm.prank(owner);
        chainAdminOwnable.setTokenMultiplierSetter(address(0));

        assertEq(chainAdminOwnable.tokenMultiplierSetter(), address(0));
    }

    // ============ setUpgradeTimestamp Tests ============

    function test_setUpgradeTimestamp_updatesMapping(uint256 protocolVersion, uint256 timestamp) public {
        vm.prank(owner);
        chainAdminOwnable.setUpgradeTimestamp(protocolVersion, timestamp);

        assertEq(chainAdminOwnable.protocolVersionToUpgradeTimestamp(protocolVersion), timestamp);
    }

    function test_setUpgradeTimestamp_emitsEvent(uint256 protocolVersion, uint256 timestamp) public {
        vm.expectEmit(true, false, false, true);
        emit UpdateUpgradeTimestamp(protocolVersion, timestamp);

        vm.prank(owner);
        chainAdminOwnable.setUpgradeTimestamp(protocolVersion, timestamp);
    }

    function test_setUpgradeTimestamp_revertsIfNotOwner(uint256 protocolVersion, uint256 timestamp) public {
        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainAdminOwnable.setUpgradeTimestamp(protocolVersion, timestamp);
    }

    function test_setUpgradeTimestamp_canOverwrite(uint256 protocolVersion) public {
        uint256 firstTimestamp = 1000;
        uint256 secondTimestamp = 2000;

        vm.startPrank(owner);
        chainAdminOwnable.setUpgradeTimestamp(protocolVersion, firstTimestamp);
        assertEq(chainAdminOwnable.protocolVersionToUpgradeTimestamp(protocolVersion), firstTimestamp);

        chainAdminOwnable.setUpgradeTimestamp(protocolVersion, secondTimestamp);
        assertEq(chainAdminOwnable.protocolVersionToUpgradeTimestamp(protocolVersion), secondTimestamp);
        vm.stopPrank();
    }

    // ============ multicall Tests ============

    function test_multicall_revertsOnEmptyCalls() public {
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](0);

        vm.prank(owner);
        vm.expectRevert(NoCallsProvided.selector);
        chainAdminOwnable.multicall(calls, false);
    }

    function test_multicall_revertsIfNotOwner() public {
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: address(mockChainContract), value: 0, data: ""});

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainAdminOwnable.multicall(calls, false);
    }

    function test_multicall_executesSuccessfulCall() public {
        bytes memory callData = abi.encodeCall(MockChainContract.setTokenMultiplier, (100, 200));
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: address(mockChainContract), value: 0, data: callData});

        vm.prank(owner);
        chainAdminOwnable.multicall(calls, true);

        assertTrue(mockChainContract.tokenMultiplierCalled());
        assertEq(mockChainContract.lastNominator(), 100);
        assertEq(mockChainContract.lastDenominator(), 200);
    }

    function test_multicall_emitsCallExecutedEvent() public {
        bytes memory callData = abi.encodeCall(MockChainContract.setTokenMultiplier, (100, 200));
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: address(mockChainContract), value: 0, data: callData});

        vm.prank(owner);
        vm.expectEmit(false, false, false, false);
        emit CallExecuted(calls[0], true, "");
        chainAdminOwnable.multicall(calls, true);
    }

    function test_multicall_revertsOnFailedCallWhenRequireSuccessTrue() public {
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: address(mockRevertingContract), value: 0, data: ""});

        vm.prank(owner);
        vm.expectRevert(MockRevertingContract.MockError.selector);
        chainAdminOwnable.multicall(calls, true);
    }

    function test_multicall_doesNotRevertOnFailedCallWhenRequireSuccessFalse() public {
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: address(mockRevertingContract), value: 0, data: ""});

        vm.prank(owner);
        chainAdminOwnable.multicall(calls, false);
        // Should not revert
    }

    function test_multicall_executesMultipleCalls() public {
        bytes memory callData1 = abi.encodeCall(MockChainContract.setTokenMultiplier, (100, 200));
        bytes memory callData2 = abi.encodeCall(MockChainContract.setTokenMultiplier, (300, 400));
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](2);
        calls[0] = IChainAdminOwnable.Call({target: address(mockChainContract), value: 0, data: callData1});
        calls[1] = IChainAdminOwnable.Call({target: address(mockChainContract), value: 0, data: callData2});

        vm.prank(owner);
        chainAdminOwnable.multicall(calls, true);

        // Last call should have set the values
        assertEq(mockChainContract.lastNominator(), 300);
        assertEq(mockChainContract.lastDenominator(), 400);
    }

    function test_multicall_sendsEtherWithCalls() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 sendAmount = 1 ether;

        // Fund the chainAdminOwnable contract
        vm.deal(address(chainAdminOwnable), sendAmount);

        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: recipient, value: sendAmount, data: ""});

        vm.prank(owner);
        chainAdminOwnable.multicall(calls, true);

        assertEq(recipient.balance, sendAmount);
    }

    // ============ setTokenMultiplier Tests ============

    function test_setTokenMultiplier_callsChainContract() public {
        uint128 nominator = 150;
        uint128 denominator = 250;

        vm.prank(tokenMultiplierSetter);
        chainAdminOwnable.setTokenMultiplier(IAdmin(address(mockChainContract)), nominator, denominator);

        assertTrue(mockChainContract.tokenMultiplierCalled());
        assertEq(mockChainContract.lastNominator(), nominator);
        assertEq(mockChainContract.lastDenominator(), denominator);
    }

    function test_setTokenMultiplier_revertsIfNotTokenMultiplierSetter() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomUser));
        chainAdminOwnable.setTokenMultiplier(IAdmin(address(mockChainContract)), 100, 200);
    }

    function test_setTokenMultiplier_revertsIfOwnerButNotSetter() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        chainAdminOwnable.setTokenMultiplier(IAdmin(address(mockChainContract)), 100, 200);
    }

    function test_setTokenMultiplier_fuzz(uint128 nominator, uint128 denominator) public {
        vm.prank(tokenMultiplierSetter);
        chainAdminOwnable.setTokenMultiplier(IAdmin(address(mockChainContract)), nominator, denominator);

        assertEq(mockChainContract.lastNominator(), nominator);
        assertEq(mockChainContract.lastDenominator(), denominator);
    }

    // ============ receive Tests ============

    function test_receive_acceptsEther() public {
        uint256 sendAmount = 1 ether;
        vm.deal(randomUser, sendAmount);

        vm.prank(randomUser);
        (bool success, ) = address(chainAdminOwnable).call{value: sendAmount}("");

        assertTrue(success);
        assertEq(address(chainAdminOwnable).balance, sendAmount);
    }

    function test_receive_acceptsEtherFromAnyone(address sender, uint256 amount) public {
        vm.assume(sender != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.deal(sender, amount);

        vm.prank(sender);
        (bool success, ) = address(chainAdminOwnable).call{value: amount}("");

        assertTrue(success);
        assertEq(address(chainAdminOwnable).balance, amount);
    }

    // ============ Ownership Tests ============

    function test_ownership_canTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        chainAdminOwnable.transferOwnership(newOwner);

        // New owner must accept
        assertEq(chainAdminOwnable.pendingOwner(), newOwner);
        assertEq(chainAdminOwnable.owner(), owner);

        vm.prank(newOwner);
        chainAdminOwnable.acceptOwnership();

        assertEq(chainAdminOwnable.owner(), newOwner);
    }

    function test_ownership_pendingOwnerCannotActBeforeAccepting() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        chainAdminOwnable.transferOwnership(newOwner);

        // New owner tries to call owner-only function before accepting
        vm.prank(newOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        chainAdminOwnable.setTokenMultiplierSetter(address(0));
    }
}
