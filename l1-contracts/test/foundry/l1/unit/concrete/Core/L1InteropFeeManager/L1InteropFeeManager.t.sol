// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropFeeManager} from "contracts/core/interop-fee/L1InteropFeeManager.sol";
import {IL1InteropFeeManager} from "contracts/core/interop-fee/IL1InteropFeeManager.sol";
import {InsufficientInteropFeeBalance} from "contracts/core/interop-fee/InteropFeeErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ZKChainNotRegistered} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {RevertFallback} from "contracts/dev-contracts/RevertFallback.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {
    AmountMustBeGreaterThanZero,
    MsgValueMismatch,
    Reentrancy,
    SlotOccupied,
    TokenNotSupported,
    Unauthorized,
    WithdrawFailed,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

contract ChainRegistryStub {
    mapping(uint256 chainId => address zkChain) public getZKChain;

    function register(uint256 _chainId, address _zkChain) external {
        getZKChain[_chainId] = _zkChain;
    }
}

contract ZKChainStub {
    address public getAdmin;

    constructor(address _admin) {
        getAdmin = _admin;
    }
}

/// @dev Calls back into the manager when it receives ether, and records how the nested call reverted.
contract ReentrantReceiver {
    L1InteropFeeManager internal immutable MANAGER;
    bytes internal reentry;
    bytes public reentryRevertData;

    constructor(L1InteropFeeManager _manager) {
        MANAGER = _manager;
    }

    function setReentry(bytes calldata _reentry) external {
        reentry = _reentry;
    }

    function withdraw(uint256 _chainId, uint256 _amount) external {
        MANAGER.withdraw(_chainId, ETH_TOKEN_ADDRESS, address(this), _amount);
    }

    receive() external payable {
        (bool success, bytes memory revertData) = address(MANAGER).call(reentry);
        require(!success, "reentered");
        reentryRevertData = revertData;
    }
}

/// @dev Calls back into the manager when it pulls a deposit, and records how the nested call reverted.
contract ReentrantToken is TestnetERC20Token {
    address internal immutable MANAGER;
    bytes internal reentry;
    bytes public reentryRevertData;

    constructor(address _manager) TestnetERC20Token("Reentrant", "RE", 18) {
        MANAGER = _manager;
    }

    function setReentry(bytes calldata _reentry) external {
        reentry = _reentry;
    }

    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        (bool success, bytes memory revertData) = MANAGER.call(reentry);
        require(!success, "reentered");
        reentryRevertData = revertData;
        return super.transferFrom(_from, _to, _amount);
    }
}

/// @dev Isolates the fee manager from the Bridgehub and the diamond: it only reads `getZKChain` and `getAdmin`,
/// so minimal stand-ins keep the setup readable. Settlement with a real diamond is covered in
/// `BatchProcessing/InteropFee.t.sol`.
contract L1InteropFeeManagerTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant OTHER_CHAIN_ID = 272;
    uint256 internal constant UNREGISTERED_CHAIN_ID = 273;
    uint256 internal constant FEE_PER_UNIT = 0.001 ether;
    uint256 internal constant TOKEN_FEE_PER_UNIT = 5e18;

    ChainRegistryStub internal registry;
    L1InteropFeeManager internal manager;
    TestnetERC20Token internal token;
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal chainAdmin = makeAddr("chainAdmin");
    address internal zkChain;

    function setUp() public {
        registry = new ChainRegistryStub();
        zkChain = address(new ZKChainStub(chainAdmin));
        registry.register(CHAIN_ID, zkChain);
        token = new TestnetERC20Token("Fee", "FEE", 18);

        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        manager = L1InteropFeeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropFeeManager.initialize, (owner, recipient))
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Initialization
    //////////////////////////////////////////////////////////////*/

    function test_initialize_startsSwitchedOffInEther() public {
        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectEmit();
        emit IL1InteropFeeManager.NewFee(address(0), 0, ETH_TOKEN_ADDRESS, 0);
        vm.expectEmit();
        emit IL1InteropFeeManager.NewFeeRecipient(address(0), recipient);
        L1InteropFeeManager freshManager = L1InteropFeeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropFeeManager.initialize, (owner, recipient))
                )
            )
        );

        assertEq(freshManager.owner(), owner);
        assertEq(freshManager.feeRecipient(), recipient);
        assertEq(freshManager.feeToken(), ETH_TOKEN_ADDRESS);
        assertEq(freshManager.feePerUnit(), 0);
        assertEq(address(freshManager.BRIDGE_HUB()), address(registry));
    }

    function test_revertWhen_initializedTwice() public {
        // The reentrancy guard's own one-time initializer trips first.
        vm.expectRevert(SlotOccupied.selector);
        manager.initialize(owner, recipient);
    }

    function test_revertWhen_implementationInitialized() public {
        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert(SlotOccupied.selector);
        impl.initialize(owner, recipient);
    }

    function test_revertWhen_initializeWithZeroOwner() public {
        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(L1InteropFeeManager.initialize, (address(0), recipient))
        );
    }

    function test_revertWhen_initializeWithZeroRecipient() public {
        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(L1InteropFeeManager.initialize, (owner, address(0)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Owner settings
    //////////////////////////////////////////////////////////////*/

    function test_setFee() public {
        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.NewFee(ETH_TOKEN_ADDRESS, 0, ETH_TOKEN_ADDRESS, FEE_PER_UNIT);
        vm.prank(owner);
        manager.setFee(ETH_TOKEN_ADDRESS, FEE_PER_UNIT);
        assertEq(manager.feeToken(), ETH_TOKEN_ADDRESS);
        assertEq(manager.feePerUnit(), FEE_PER_UNIT);

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.NewFee(ETH_TOKEN_ADDRESS, FEE_PER_UNIT, address(token), TOKEN_FEE_PER_UNIT);
        vm.prank(owner);
        manager.setFee(address(token), TOKEN_FEE_PER_UNIT);
        assertEq(manager.feeToken(), address(token));
        assertEq(manager.feePerUnit(), TOKEN_FEE_PER_UNIT);

        // Turning the switch back off is a plain update to zero.
        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.NewFee(address(token), TOKEN_FEE_PER_UNIT, address(token), 0);
        vm.prank(owner);
        manager.setFee(address(token), 0);
        assertEq(manager.feeToken(), address(token));
        assertEq(manager.feePerUnit(), 0);
    }

    function test_revertWhen_setFeeByNonOwner() public {
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.setFee(ETH_TOKEN_ADDRESS, FEE_PER_UNIT);
    }

    function test_revertWhen_setFeeTokenToZero() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        manager.setFee(address(0), FEE_PER_UNIT);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.NewFeeRecipient(recipient, newRecipient);
        vm.prank(owner);
        manager.setFeeRecipient(newRecipient);
        assertEq(manager.feeRecipient(), newRecipient);
    }

    function test_revertWhen_setFeeRecipientToZero() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        manager.setFeeRecipient(address(0));
    }

    function test_revertWhen_setFeeRecipientByNonOwner() public {
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.setFeeRecipient(makeAddr("newRecipient"));
    }

    /*//////////////////////////////////////////////////////////////
                            Deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function test_deposit_creditsChainBalance() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 2 ether);

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.ChainBalanceDeposited(CHAIN_ID, ETH_TOKEN_ADDRESS, depositor, 1 ether);
        vm.prank(depositor);
        manager.deposit{value: 1 ether}(CHAIN_ID, ETH_TOKEN_ADDRESS, 1 ether);

        vm.prank(depositor);
        manager.deposit{value: 0.5 ether}(CHAIN_ID, ETH_TOKEN_ADDRESS, 0.5 ether);

        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 1.5 ether);
        assertEq(address(manager).balance, 1.5 ether);
    }

    function test_deposit_pullsErc20FeeToken() public {
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        address depositor = makeAddr("depositor");
        token.mint(depositor, 10e18);

        vm.startPrank(depositor);
        token.approve(address(manager), 10e18);
        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.ChainBalanceDeposited(CHAIN_ID, address(token), depositor, 7e18);
        manager.deposit(CHAIN_ID, address(token), 7e18);
        vm.stopPrank();

        assertEq(manager.chainBalance(CHAIN_ID, address(token)), 7e18);
        assertEq(token.balanceOf(address(manager)), 7e18);
        assertEq(token.balanceOf(depositor), 3e18);
    }

    function test_revertWhen_depositInAnotherTokenThanTheFeeToken() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, address(token)));
        manager.deposit(CHAIN_ID, address(token), 1e18);

        // A deposit made for the former fee token reverts instead of landing in the new one.
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, ETH_TOKEN_ADDRESS));
        manager.deposit{value: 1 ether}(CHAIN_ID, ETH_TOKEN_ADDRESS, 1 ether);
    }

    function test_revertWhen_depositZero() public {
        vm.expectRevert(AmountMustBeGreaterThanZero.selector);
        manager.deposit{value: 0}(CHAIN_ID, ETH_TOKEN_ADDRESS, 0);
    }

    function test_revertWhen_depositEtherOtherThanTheAmount() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, 2 ether, 1 ether));
        manager.deposit{value: 1 ether}(CHAIN_ID, ETH_TOKEN_ADDRESS, 2 ether);
    }

    function test_revertWhen_depositErc20WithEther() public {
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        token.mint(address(this), 1e18);
        token.approve(address(manager), 1e18);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, 0, 1 ether));
        manager.deposit{value: 1 ether}(CHAIN_ID, address(token), 1e18);
    }

    function test_revertWhen_depositToUnregisteredChain() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ZKChainNotRegistered.selector);
        manager.deposit{value: 1 ether}(UNREGISTERED_CHAIN_ID, ETH_TOKEN_ADDRESS, 1 ether);
    }

    function test_deposit_cannotBeReentered() public {
        ReentrantToken reentrantToken = new ReentrantToken(address(manager));
        _setFee(address(reentrantToken), TOKEN_FEE_PER_UNIT);
        reentrantToken.mint(address(this), 2e18);
        reentrantToken.approve(address(manager), 2e18);
        reentrantToken.setReentry(
            abi.encodeCall(L1InteropFeeManager.deposit, (CHAIN_ID, address(reentrantToken), 1e18))
        );

        manager.deposit(CHAIN_ID, address(reentrantToken), 1e18);

        assertEq(reentrantToken.reentryRevertData(), abi.encodeWithSelector(Reentrancy.selector));
        assertEq(manager.chainBalance(CHAIN_ID, address(reentrantToken)), 1e18);
        assertEq(reentrantToken.balanceOf(address(manager)), 1e18);
    }

    function test_withdraw_byChainAdmin() public {
        _fund(1 ether);
        address payable to = payable(makeAddr("to"));

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.ChainBalanceWithdrawn(CHAIN_ID, ETH_TOKEN_ADDRESS, to, 0.4 ether);
        vm.prank(chainAdmin);
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, to, 0.4 ether);

        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 0.6 ether);
        assertEq(to.balance, 0.4 ether);
        assertEq(address(manager).balance, 0.6 ether);
    }

    function test_withdraw_erc20() public {
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        _fundToken(10e18);
        address to = makeAddr("to");

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.ChainBalanceWithdrawn(CHAIN_ID, address(token), to, 4e18);
        vm.prank(chainAdmin);
        manager.withdraw(CHAIN_ID, address(token), to, 4e18);

        assertEq(manager.chainBalance(CHAIN_ID, address(token)), 6e18);
        assertEq(token.balanceOf(to), 4e18);
        assertEq(token.balanceOf(address(manager)), 6e18);
    }

    function test_withdraw_formerFeeTokenAfterSwitch() public {
        _fund(1 ether);
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        address payable to = payable(makeAddr("to"));

        vm.prank(chainAdmin);
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, to, 1 ether);

        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 0);
        assertEq(to.balance, 1 ether);
    }

    function test_revertWhen_withdrawByNonAdmin() public {
        _fund(1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, owner, 1 ether);
    }

    function test_revertWhen_withdrawZero() public {
        _fund(1 ether);
        vm.prank(chainAdmin);
        vm.expectRevert(AmountMustBeGreaterThanZero.selector);
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, chainAdmin, 0);
    }

    function test_revertWhen_withdrawMoreThanBalance() public {
        _fund(1 ether);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InsufficientInteropFeeBalance.selector, CHAIN_ID, 1 ether, 2 ether));
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, chainAdmin, 2 ether);
    }

    function test_revertWhen_withdrawToZeroAddress() public {
        _fund(1 ether);
        vm.prank(chainAdmin);
        vm.expectRevert(ZeroAddress.selector);
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, address(0), 1 ether);
    }

    function test_revertWhen_withdrawRecipientRejectsEther() public {
        _fund(1 ether);
        address rejecter = address(new RevertFallback());
        vm.prank(chainAdmin);
        vm.expectRevert(WithdrawFailed.selector);
        manager.withdraw(CHAIN_ID, ETH_TOKEN_ADDRESS, rejecter, 1 ether);
    }

    function test_withdraw_cannotBeReentered() public {
        ReentrantReceiver admin = new ReentrantReceiver(manager);
        registry.register(OTHER_CHAIN_ID, address(new ZKChainStub(address(admin))));
        vm.deal(address(this), 1 ether);
        manager.deposit{value: 1 ether}(OTHER_CHAIN_ID, ETH_TOKEN_ADDRESS, 1 ether);
        admin.setReentry(
            abi.encodeCall(L1InteropFeeManager.withdraw, (OTHER_CHAIN_ID, ETH_TOKEN_ADDRESS, address(admin), 0.4 ether))
        );

        admin.withdraw(OTHER_CHAIN_ID, 0.4 ether);

        assertEq(admin.reentryRevertData(), abi.encodeWithSelector(Reentrancy.selector));
        assertEq(address(admin).balance, 0.4 ether);
        assertEq(manager.chainBalance(OTHER_CHAIN_ID, ETH_TOKEN_ADDRESS), 0.6 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            Charging
    //////////////////////////////////////////////////////////////*/

    function test_charge_debitsBalanceAndAccrues() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.InteropFeeCharged(CHAIN_ID, 5, ETH_TOKEN_ADDRESS, 3, 3 * FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 5, 3);

        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 1 ether - 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 3 * FEE_PER_UNIT);
        // Charging moves value between internal ledgers only.
        assertEq(address(manager).balance, 1 ether);
    }

    function test_charge_inTheFeeTokenOnly() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, 3);

        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        _fundToken(10e18);
        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.InteropFeeCharged(CHAIN_ID, 2, address(token), 2, 2 * TOKEN_FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 2, 2);

        assertEq(manager.chainBalance(CHAIN_ID, address(token)), 10e18 - 2 * TOKEN_FEE_PER_UNIT);
        assertEq(manager.accruedFees(address(token)), 2 * TOKEN_FEE_PER_UNIT);
        // The ether ledgers are left as the switch found them.
        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 1 ether - 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 3 * FEE_PER_UNIT);
    }

    function test_revertWhen_chargedInANewTokenWithoutABalanceInIt() public {
        _fund(1 ether);
        _setFee(address(token), TOKEN_FEE_PER_UNIT);

        vm.prank(zkChain);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientInteropFeeBalance.selector, CHAIN_ID, 0, TOKEN_FEE_PER_UNIT)
        );
        manager.chargeInteropFee(CHAIN_ID, 1, 1);
    }

    function test_charge_isNoOpWhileSwitchedOff() public {
        // The chain has no balance: while the switch is off, execution never depends on one.
        vm.recordLogs();
        vm.expectCall(address(registry), abi.encodeWithSelector(IBridgehubBase.getZKChain.selector), 0);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 5, 3);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 0);
    }

    function test_charge_exactBalance() public {
        _fund(3 * FEE_PER_UNIT);
        _setFee(FEE_PER_UNIT);

        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, 3);

        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 0);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 3 * FEE_PER_UNIT);
    }

    function test_revertWhen_chargeExceedsBalance() public {
        _fund(2 * FEE_PER_UNIT);
        _setFee(FEE_PER_UNIT);

        vm.prank(zkChain);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientInteropFeeBalance.selector, CHAIN_ID, 2 * FEE_PER_UNIT, 3 * FEE_PER_UNIT)
        );
        manager.chargeInteropFee(CHAIN_ID, 1, 3);
    }

    function test_revertWhen_chargeOverflows() public {
        _fund(1 ether);
        _setFee(type(uint256).max);

        vm.prank(zkChain);
        vm.expectRevert(stdError.arithmeticError);
        manager.chargeInteropFee(CHAIN_ID, 1, 2);
    }

    function test_revertWhen_chargedByNonDiamond() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
        manager.chargeInteropFee(CHAIN_ID, 1, 3);
    }

    function test_revertWhen_chargedForAnotherChain() public {
        // A registered diamond can only charge its own chain.
        address otherZkChain = address(new ZKChainStub(chainAdmin));
        registry.register(OTHER_CHAIN_ID, otherZkChain);
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);

        vm.prank(otherZkChain);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherZkChain));
        manager.chargeInteropFee(CHAIN_ID, 1, 3);
    }

    function test_revertWhen_chargedForUnregisteredChain() public {
        _setFee(FEE_PER_UNIT);
        vm.prank(zkChain);
        vm.expectRevert(ZKChainNotRegistered.selector);
        manager.chargeInteropFee(UNREGISTERED_CHAIN_ID, 1, 3);
    }

    /*//////////////////////////////////////////////////////////////
                            Sweeping
    //////////////////////////////////////////////////////////////*/

    function test_sweep_sendsAccruedFeesToRecipient() public {
        _accrue(3);

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.FeesSwept(ETH_TOKEN_ADDRESS, recipient, 3 * FEE_PER_UNIT);
        // Permissionless: the destination is fixed by the owner.
        vm.prank(makeAddr("anyone"));
        manager.sweep(ETH_TOKEN_ADDRESS);

        assertEq(recipient.balance, 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 0);
        // Prepaid balances stay in the contract.
        assertEq(address(manager).balance, 1 ether - 3 * FEE_PER_UNIT);
        assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), 1 ether - 3 * FEE_PER_UNIT);
    }

    function test_sweep_eachTokenSeparately() public {
        // Fees accrued in ether before the switch, and in the ERC20 after it.
        _accrue(3);
        _setFee(address(token), TOKEN_FEE_PER_UNIT);
        _fundToken(10e18);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 2, 2);

        vm.expectEmit(address(manager));
        emit IL1InteropFeeManager.FeesSwept(address(token), recipient, 2 * TOKEN_FEE_PER_UNIT);
        manager.sweep(address(token));
        assertEq(token.balanceOf(recipient), 2 * TOKEN_FEE_PER_UNIT);
        assertEq(manager.accruedFees(address(token)), 0);
        assertEq(token.balanceOf(address(manager)), 10e18 - 2 * TOKEN_FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 3 * FEE_PER_UNIT);

        // Fees accrued in a former fee token can still be swept.
        manager.sweep(ETH_TOKEN_ADDRESS);
        assertEq(recipient.balance, 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 0);
    }

    function test_sweep_isNoOpWithoutAccruedFees() public {
        _fund(1 ether);
        vm.recordLogs();
        manager.sweep(ETH_TOKEN_ADDRESS);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(recipient.balance, 0);
    }

    function test_revertWhen_sweepRecipientRejectsEther() public {
        _accrue(3);
        _setRecipient(address(new RevertFallback()));

        vm.expectRevert(WithdrawFailed.selector);
        manager.sweep(ETH_TOKEN_ADDRESS);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 3 * FEE_PER_UNIT);
    }

    function test_sweep_cannotBeReentered() public {
        _accrue(3);
        ReentrantReceiver reentrantRecipient = new ReentrantReceiver(manager);
        reentrantRecipient.setReentry(abi.encodeCall(L1InteropFeeManager.sweep, (ETH_TOKEN_ADDRESS)));
        _setRecipient(address(reentrantRecipient));

        manager.sweep(ETH_TOKEN_ADDRESS);

        assertEq(reentrantRecipient.reentryRevertData(), abi.encodeWithSelector(Reentrancy.selector));
        assertEq(address(reentrantRecipient).balance, 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            Fuzz
    //////////////////////////////////////////////////////////////*/

    /// @dev A charge either takes exactly `fee * units` or reverts, and never creates or destroys value.
    function testFuzz_charge_conservesValue(uint96 _deposit, uint64 _feePerUnit, uint32 _units) public {
        if (_deposit != 0) {
            _fund(_deposit);
        }
        _setFee(_feePerUnit);
        uint256 fee = uint256(_feePerUnit) * _units;

        vm.prank(zkChain);
        if (fee > _deposit) {
            vm.expectRevert(abi.encodeWithSelector(InsufficientInteropFeeBalance.selector, CHAIN_ID, _deposit, fee));
            manager.chargeInteropFee(CHAIN_ID, 1, _units);
            assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), _deposit);
        } else {
            manager.chargeInteropFee(CHAIN_ID, 1, _units);
            assertEq(manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS), _deposit - fee);
            assertEq(manager.accruedFees(ETH_TOKEN_ADDRESS), fee);
        }
        assertEq(
            address(manager).balance,
            manager.chainBalance(CHAIN_ID, ETH_TOKEN_ADDRESS) + manager.accruedFees(ETH_TOKEN_ADDRESS)
        );
    }

    function _fund(uint256 _amount) internal {
        vm.deal(address(this), _amount);
        manager.deposit{value: _amount}(CHAIN_ID, ETH_TOKEN_ADDRESS, _amount);
    }

    /// @dev Funds the chain in the ERC20, which must be the fee token.
    function _fundToken(uint256 _amount) internal {
        token.mint(address(this), _amount);
        token.approve(address(manager), _amount);
        manager.deposit(CHAIN_ID, address(token), _amount);
    }

    function _setFee(uint256 _feePerUnit) internal {
        _setFee(ETH_TOKEN_ADDRESS, _feePerUnit);
    }

    function _setFee(address _feeToken, uint256 _feePerUnit) internal {
        vm.prank(owner);
        manager.setFee(_feeToken, _feePerUnit);
    }

    function _setRecipient(address _feeRecipient) internal {
        vm.prank(owner);
        manager.setFeeRecipient(_feeRecipient);
    }

    /// @dev Funds the chain with 1 ether and charges it for `_units` units.
    function _accrue(uint256 _units) internal {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, _units);
    }
}
