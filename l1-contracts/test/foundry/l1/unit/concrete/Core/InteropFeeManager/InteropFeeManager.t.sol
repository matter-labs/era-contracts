// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {InteropFeeManager} from "contracts/core/interop-fee/InteropFeeManager.sol";
import {IInteropFeeManager} from "contracts/core/interop-fee/IInteropFeeManager.sol";
import {InsufficientInteropFeeBalance, InteropFeeTransferFailed} from "contracts/core/interop-fee/InteropFeeErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ZKChainNotRegistered} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {
    AmountMustBeGreaterThanZero,
    SlotOccupied,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

/// @dev These tests isolate the fee manager from the Bridgehub and the diamond: the manager only reads
/// `getZKChain` and `getAdmin`, so minimal stand-ins keep the setup readable. The full commit path with a
/// real diamond is covered in `BatchProcessing/InteropFee.t.sol`.
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

contract EtherRejecter {
    receive() external payable {
        revert("no ether");
    }
}

contract InteropFeeManagerTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant UNREGISTERED_CHAIN_ID = 272;
    uint256 internal constant FEE_PER_UNIT = 0.001 ether;

    ChainRegistryStub internal registry;
    InteropFeeManager internal manager;
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal chainAdmin = makeAddr("chainAdmin");
    address internal zkChain;

    function setUp() public {
        registry = new ChainRegistryStub();
        zkChain = address(new ZKChainStub(chainAdmin));
        registry.register(CHAIN_ID, zkChain);

        InteropFeeManager impl = new InteropFeeManager(IBridgehubBase(address(registry)));
        manager = InteropFeeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(InteropFeeManager.initialize, (owner, recipient))
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Initialization
    //////////////////////////////////////////////////////////////*/

    function test_initialize_startsSwitchedOff() public view {
        assertEq(manager.owner(), owner);
        assertEq(manager.feeRecipient(), recipient);
        assertEq(manager.feePerUnit(), 0);
        assertEq(manager.accruedFees(), 0);
        assertEq(address(manager.BRIDGE_HUB()), address(registry));
    }

    function test_revertWhen_initializedTwice() public {
        // The reentrancy guard's own one-time initializer trips first.
        vm.expectRevert(SlotOccupied.selector);
        manager.initialize(owner, recipient);
    }

    function test_revertWhen_implementationInitialized() public {
        InteropFeeManager impl = new InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(owner, recipient);
    }

    function test_revertWhen_initializeWithZeroOwner() public {
        InteropFeeManager impl = new InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(InteropFeeManager.initialize, (address(0), recipient))
        );
    }

    function test_revertWhen_initializeWithZeroRecipient() public {
        InteropFeeManager impl = new InteropFeeManager(IBridgehubBase(address(registry)));
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(InteropFeeManager.initialize, (owner, address(0)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Owner settings
    //////////////////////////////////////////////////////////////*/

    function test_setFeePerUnit() public {
        vm.expectEmit(address(manager));
        emit IInteropFeeManager.FeePerUnitSet(0, FEE_PER_UNIT);
        vm.prank(owner);
        manager.setFeePerUnit(FEE_PER_UNIT);
        assertEq(manager.feePerUnit(), FEE_PER_UNIT);

        // Turning the switch back off is a plain update to zero.
        vm.expectEmit(address(manager));
        emit IInteropFeeManager.FeePerUnitSet(FEE_PER_UNIT, 0);
        vm.prank(owner);
        manager.setFeePerUnit(0);
        assertEq(manager.feePerUnit(), 0);
    }

    function test_revertWhen_setFeePerUnitByNonOwner() public {
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.setFeePerUnit(FEE_PER_UNIT);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(address(manager));
        emit IInteropFeeManager.FeeRecipientSet(recipient, newRecipient);
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

    function test_ownershipTransferIsTwoStep() public {
        address governance = makeAddr("governance");
        vm.prank(owner);
        manager.transferOwnership(governance);
        assertEq(manager.owner(), owner);
        assertEq(manager.pendingOwner(), governance);

        vm.prank(governance);
        manager.acceptOwnership();
        assertEq(manager.owner(), governance);
    }

    /*//////////////////////////////////////////////////////////////
                            Deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function test_deposit_creditsChainBalance() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 2 ether);

        vm.expectEmit(address(manager));
        emit IInteropFeeManager.Deposited(CHAIN_ID, depositor, 1 ether);
        vm.prank(depositor);
        manager.deposit{value: 1 ether}(CHAIN_ID);

        vm.prank(depositor);
        manager.deposit{value: 0.5 ether}(CHAIN_ID);

        assertEq(manager.chainBalance(CHAIN_ID), 1.5 ether);
        assertEq(address(manager).balance, 1.5 ether);
    }

    function test_revertWhen_depositZero() public {
        vm.expectRevert(AmountMustBeGreaterThanZero.selector);
        manager.deposit{value: 0}(CHAIN_ID);
    }

    function test_revertWhen_depositToUnregisteredChain() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ZKChainNotRegistered.selector);
        manager.deposit{value: 1 ether}(UNREGISTERED_CHAIN_ID);
    }

    function test_withdraw_byChainAdmin() public {
        _fund(1 ether);
        address payable to = payable(makeAddr("to"));

        vm.expectEmit(address(manager));
        emit IInteropFeeManager.Withdrawn(CHAIN_ID, to, 0.4 ether);
        vm.prank(chainAdmin);
        manager.withdraw(CHAIN_ID, to, 0.4 ether);

        assertEq(manager.chainBalance(CHAIN_ID), 0.6 ether);
        assertEq(to.balance, 0.4 ether);
        assertEq(address(manager).balance, 0.6 ether);
    }

    function test_revertWhen_withdrawByNonAdmin() public {
        _fund(1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        manager.withdraw(CHAIN_ID, owner, 1 ether);
    }

    function test_revertWhen_withdrawMoreThanBalance() public {
        _fund(1 ether);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InsufficientInteropFeeBalance.selector, CHAIN_ID, 1 ether, 2 ether));
        manager.withdraw(CHAIN_ID, chainAdmin, 2 ether);
    }

    function test_revertWhen_withdrawToZeroAddress() public {
        _fund(1 ether);
        vm.prank(chainAdmin);
        vm.expectRevert(ZeroAddress.selector);
        manager.withdraw(CHAIN_ID, address(0), 1 ether);
    }

    function test_revertWhen_withdrawRecipientRejectsEther() public {
        _fund(1 ether);
        address rejecter = address(new EtherRejecter());
        vm.prank(chainAdmin);
        vm.expectRevert(InteropFeeTransferFailed.selector);
        manager.withdraw(CHAIN_ID, rejecter, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            Charging
    //////////////////////////////////////////////////////////////*/

    function test_charge_debitsBalanceAndAccrues() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);

        vm.expectEmit(address(manager));
        emit IInteropFeeManager.InteropFeeCharged(CHAIN_ID, 5, 3, 3 * FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 5, 3);

        assertEq(manager.chainBalance(CHAIN_ID), 1 ether - 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(), 3 * FEE_PER_UNIT);
        // Charging moves value between internal ledgers only.
        assertEq(address(manager).balance, 1 ether);
    }

    function test_charge_isNoOpWhileSwitchedOff() public {
        _fund(1 ether);

        vm.recordLogs();
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 5, 3);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(manager.chainBalance(CHAIN_ID), 1 ether);
        assertEq(manager.accruedFees(), 0);
    }

    function test_charge_doesNotRequireBalanceWhileSwitchedOff() public {
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 5, 3);
        assertEq(manager.accruedFees(), 0);
    }

    function test_charge_exactBalance() public {
        _fund(3 * FEE_PER_UNIT);
        _setFee(FEE_PER_UNIT);

        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, 3);

        assertEq(manager.chainBalance(CHAIN_ID), 0);
        assertEq(manager.accruedFees(), 3 * FEE_PER_UNIT);
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
        registry.register(UNREGISTERED_CHAIN_ID, otherZkChain);
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);

        vm.prank(otherZkChain);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherZkChain));
        manager.chargeInteropFee(CHAIN_ID, 1, 3);
    }

    function test_revertWhen_chargedForUnregisteredChain() public {
        vm.prank(zkChain);
        vm.expectRevert(ZKChainNotRegistered.selector);
        manager.chargeInteropFee(UNREGISTERED_CHAIN_ID, 1, 3);
    }

    /*//////////////////////////////////////////////////////////////
                            Sweeping
    //////////////////////////////////////////////////////////////*/

    function test_sweep_sendsAccruedFeesToRecipient() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, 3);

        vm.expectEmit(address(manager));
        emit IInteropFeeManager.FeesSwept(recipient, 3 * FEE_PER_UNIT);
        // Permissionless: the destination is fixed by the owner.
        vm.prank(makeAddr("anyone"));
        manager.sweep();

        assertEq(recipient.balance, 3 * FEE_PER_UNIT);
        assertEq(manager.accruedFees(), 0);
        // Prepaid balances stay in the contract.
        assertEq(address(manager).balance, 1 ether - 3 * FEE_PER_UNIT);
        assertEq(manager.chainBalance(CHAIN_ID), 1 ether - 3 * FEE_PER_UNIT);
    }

    function test_sweep_isNoOpWithoutAccruedFees() public {
        _fund(1 ether);
        vm.recordLogs();
        manager.sweep();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(recipient.balance, 0);
    }

    function test_revertWhen_sweepRecipientRejectsEther() public {
        _fund(1 ether);
        _setFee(FEE_PER_UNIT);
        vm.prank(zkChain);
        manager.chargeInteropFee(CHAIN_ID, 1, 3);

        address rejecter = address(new EtherRejecter());
        vm.prank(owner);
        manager.setFeeRecipient(rejecter);

        vm.expectRevert(InteropFeeTransferFailed.selector);
        manager.sweep();
        assertEq(manager.accruedFees(), 3 * FEE_PER_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                            Fuzz
    //////////////////////////////////////////////////////////////*/

    /// @dev Charging never creates or destroys value: the contract's ether always equals the prepaid
    /// balances plus the accrued fees, and a charge either takes exactly `fee * units` or reverts.
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
            assertEq(manager.chainBalance(CHAIN_ID), _deposit);
        } else {
            manager.chargeInteropFee(CHAIN_ID, 1, _units);
            assertEq(manager.chainBalance(CHAIN_ID), _deposit - fee);
            assertEq(manager.accruedFees(), fee);
        }
        assertEq(address(manager).balance, manager.chainBalance(CHAIN_ID) + manager.accruedFees());
    }

    function _fund(uint256 _amount) internal {
        vm.deal(address(this), _amount);
        manager.deposit{value: _amount}(CHAIN_ID);
    }

    function _setFee(uint256 _feePerUnit) internal {
        vm.prank(owner);
        manager.setFeePerUnit(_feePerUnit);
    }
}
