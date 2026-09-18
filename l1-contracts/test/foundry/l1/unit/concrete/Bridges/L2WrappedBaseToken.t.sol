// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2WrappedBaseToken} from "contracts/bridge/L2WrappedBaseToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import {
    BridgeMintNotImplemented,
    Unauthorized,
    WithdrawFailed,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Unit tests for L2WrappedBaseToken contract
contract L2WrappedBaseTokenTest is Test {
    L2WrappedBaseToken implementation;
    L2WrappedBaseToken token;
    address l2Bridge;
    address l1Address;
    bytes32 baseTokenAssetId;

    function setUp() public {
        implementation = new L2WrappedBaseToken();
        l2Bridge = makeAddr("l2Bridge");
        l1Address = makeAddr("l1Address");
        baseTokenAssetId = keccak256(abi.encode("baseTokenAssetId"));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), bytes(""));
        token = L2WrappedBaseToken(payable(address(proxy)));
        token.initializeV3("Wrapped Ether", "WETH", l2Bridge, l1Address, baseTokenAssetId);
    }

    // ============ initializeV3 Tests ============

    function test_initializeV3_setsName() public view {
        assertEq(token.name(), "Wrapped Ether");
    }

    function test_initializeV3_setsSymbol() public view {
        assertEq(token.symbol(), "WETH");
    }

    function test_initializeV3_setsL2Bridge() public view {
        assertEq(token.l2Bridge(), l2Bridge);
    }

    function test_initializeV3_setsL1Address() public view {
        assertEq(token.l1Address(), l1Address);
    }

    function test_initializeV3_setsBaseTokenAssetId() public view {
        assertEq(token.baseTokenAssetId(), baseTokenAssetId);
    }

    function test_initializeV3_setsNativeTokenVault() public view {
        assertEq(token.nativeTokenVault(), L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    function test_initializeV3_revertsOnZeroL2Bridge() public {
        ERC1967Proxy newProxy = new ERC1967Proxy(address(implementation), bytes(""));
        L2WrappedBaseToken newToken = L2WrappedBaseToken(payable(address(newProxy)));

        vm.expectRevert(ZeroAddress.selector);
        newToken.initializeV3("WETH", "WETH", address(0), l1Address, baseTokenAssetId);
    }

    function test_initializeV3_revertsOnZeroL1Address() public {
        ERC1967Proxy newProxy = new ERC1967Proxy(address(implementation), bytes(""));
        L2WrappedBaseToken newToken = L2WrappedBaseToken(payable(address(newProxy)));

        vm.expectRevert(ZeroAddress.selector);
        newToken.initializeV3("WETH", "WETH", l2Bridge, address(0), baseTokenAssetId);
    }

    function test_initializeV3_revertsOnZeroAssetId() public {
        ERC1967Proxy newProxy = new ERC1967Proxy(address(implementation), bytes(""));
        L2WrappedBaseToken newToken = L2WrappedBaseToken(payable(address(newProxy)));

        vm.expectRevert(ZeroAddress.selector);
        newToken.initializeV3("WETH", "WETH", l2Bridge, l1Address, bytes32(0));
    }

    // ============ deposit/depositTo Tests ============

    function test_deposit_mintsTokens() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 10 ether);

        vm.prank(depositor);
        token.deposit{value: 5 ether}();

        assertEq(token.balanceOf(depositor), 5 ether);
        assertEq(address(token).balance, 5 ether);
    }

    function test_depositTo_mintsTokensToRecipient() public {
        address depositor = makeAddr("depositor");
        address recipient = makeAddr("recipient");
        vm.deal(depositor, 10 ether);

        vm.prank(depositor);
        token.depositTo{value: 3 ether}(recipient);

        assertEq(token.balanceOf(depositor), 0);
        assertEq(token.balanceOf(recipient), 3 ether);
        assertEq(address(token).balance, 3 ether);
    }

    function test_receive_mintsTokens() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 10 ether);

        vm.prank(depositor);
        (bool success, ) = address(token).call{value: 2 ether}("");

        assertTrue(success);
        assertEq(token.balanceOf(depositor), 2 ether);
        assertEq(address(token).balance, 2 ether);
    }

    // ============ withdraw/withdrawTo Tests ============

    function test_withdraw_burnsTokensAndSendsEther() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);

        vm.prank(user);
        token.deposit{value: 5 ether}();

        uint256 balanceBefore = user.balance;

        vm.prank(user);
        token.withdraw(3 ether);

        assertEq(token.balanceOf(user), 2 ether);
        assertEq(user.balance, balanceBefore + 3 ether);
    }

    function test_withdrawTo_sendsEtherToRecipient() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        vm.deal(user, 10 ether);

        vm.prank(user);
        token.deposit{value: 5 ether}();

        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(user);
        token.withdrawTo(recipient, 3 ether);

        assertEq(token.balanceOf(user), 2 ether);
        assertEq(recipient.balance, recipientBalanceBefore + 3 ether);
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);

        vm.prank(user);
        token.deposit{value: 1 ether}();

        vm.prank(user);
        vm.expectRevert();
        token.withdraw(5 ether);
    }

    // ============ bridgeMint Tests ============

    function test_bridgeMint_alwaysReverts() public {
        vm.prank(l2Bridge);
        vm.expectRevert(BridgeMintNotImplemented.selector);
        token.bridgeMint(address(0xCAFE), 100);
    }

    function test_bridgeMint_revertsIfNotBridge() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        token.bridgeMint(address(0xCAFE), 100);
    }

    // ============ bridgeBurn Tests ============

    function test_bridgeBurn_burnsAndSendsEtherToBridge() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);

        vm.prank(user);
        token.deposit{value: 5 ether}();

        uint256 bridgeBalanceBefore = l2Bridge.balance;

        vm.prank(l2Bridge);
        token.bridgeBurn(user, 3 ether);

        assertEq(token.balanceOf(user), 2 ether);
        assertEq(l2Bridge.balance, bridgeBalanceBefore + 3 ether);
    }

    function test_bridgeBurn_revertsIfNotBridge() public {
        address user = makeAddr("user");
        vm.deal(user, 10 ether);

        vm.prank(user);
        token.deposit{value: 5 ether}();

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        token.bridgeBurn(user, 1 ether);
    }

    function test_bridgeBurn_revertsOnInsufficientBalance() public {
        address user = makeAddr("user");
        vm.deal(user, 1 ether);

        vm.prank(user);
        token.deposit{value: 1 ether}();

        vm.prank(l2Bridge);
        vm.expectRevert();
        token.bridgeBurn(user, 5 ether);
    }

    // ============ originToken/assetId Tests ============

    function test_originToken_returnsL1Address() public view {
        assertEq(token.originToken(), l1Address);
    }

    function test_assetId_returnsBaseTokenAssetId() public view {
        assertEq(token.assetId(), baseTokenAssetId);
    }

    // ============ totalSupply Tests ============

    function test_totalSupply_tracksDepositsAndWithdrawals() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        vm.prank(user1);
        token.deposit{value: 5 ether}();
        assertEq(token.totalSupply(), 5 ether);

        vm.prank(user2);
        token.deposit{value: 3 ether}();
        assertEq(token.totalSupply(), 8 ether);

        vm.prank(user1);
        token.withdraw(2 ether);
        assertEq(token.totalSupply(), 6 ether);
    }

    // ============ ERC20 Standard Tests ============

    function test_transfer_works() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        vm.deal(user1, 10 ether);

        vm.prank(user1);
        token.deposit{value: 5 ether}();

        vm.prank(user1);
        bool success = token.transfer(user2, 2 ether);

        assertTrue(success);
        assertEq(token.balanceOf(user1), 3 ether);
        assertEq(token.balanceOf(user2), 2 ether);
    }

    function test_approve_and_transferFrom() public {
        address user1 = makeAddr("user1");
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        vm.deal(user1, 10 ether);

        vm.prank(user1);
        token.deposit{value: 5 ether}();

        vm.prank(user1);
        token.approve(spender, 3 ether);

        vm.prank(spender);
        bool success = token.transferFrom(user1, recipient, 2 ether);

        assertTrue(success);
        assertEq(token.balanceOf(user1), 3 ether);
        assertEq(token.balanceOf(recipient), 2 ether);
        assertEq(token.allowance(user1, spender), 1 ether);
    }

    // ============ Fuzz Tests ============

    function testFuzz_deposit(uint128 amount) public {
        vm.assume(amount > 0);
        address user = makeAddr("user");
        vm.deal(user, amount);

        vm.prank(user);
        token.deposit{value: amount}();

        assertEq(token.balanceOf(user), amount);
        assertEq(token.totalSupply(), amount);
        assertEq(address(token).balance, amount);
    }

    function testFuzz_depositAndWithdraw(uint128 depositAmount, uint128 withdrawAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(withdrawAmount > 0);
        vm.assume(withdrawAmount <= depositAmount);

        address user = makeAddr("user");
        vm.deal(user, depositAmount);

        vm.prank(user);
        token.deposit{value: depositAmount}();

        uint256 userBalanceBefore = user.balance;

        vm.prank(user);
        token.withdraw(withdrawAmount);

        assertEq(token.balanceOf(user), depositAmount - withdrawAmount);
        assertEq(user.balance, userBalanceBefore + withdrawAmount);
    }

    function testFuzz_depositTo(address recipient, uint128 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount > 0);

        address depositor = makeAddr("depositor");
        vm.deal(depositor, amount);

        vm.prank(depositor);
        token.depositTo{value: amount}(recipient);

        assertEq(token.balanceOf(recipient), amount);
    }
}
