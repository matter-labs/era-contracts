// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {InteropFeeManager} from "contracts/core/interop-fee/InteropFeeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {ChainRegistryStub, ZKChainStub} from "./InteropFeeManager.t.sol";

/// @dev Drives the manager through every state-changing entry point, each from its authorized caller, and tracks
/// the value that moved through it.
contract InteropFeeManagerHandler is Test {
    InteropFeeManager internal immutable MANAGER;
    address internal immutable OWNER;
    address internal immutable WITHDRAWAL_RECEIVER = makeAddr("withdrawalReceiver");

    uint256[] internal chainIds;
    mapping(uint256 chainId => address zkChain) internal zkChains;
    mapping(uint256 chainId => address admin) internal admins;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostCharged;
    uint256 public ghostSwept;

    constructor(InteropFeeManager _manager, address _owner, ChainRegistryStub _registry, uint256[] memory _chainIds) {
        MANAGER = _manager;
        OWNER = _owner;
        chainIds = _chainIds;
        for (uint256 i = 0; i < _chainIds.length; ++i) {
            address admin = makeAddr(string.concat("admin", vm.toString(_chainIds[i])));
            address zkChain = address(new ZKChainStub(admin));
            _registry.register(_chainIds[i], zkChain);
            zkChains[_chainIds[i]] = zkChain;
            admins[_chainIds[i]] = admin;
        }
    }

    function deposit(uint256 _chainSeed, uint96 _amount) external {
        uint256 chainId = _chain(_chainSeed);
        uint256 amount = bound(_amount, 1, type(uint96).max);
        vm.deal(address(this), amount);
        MANAGER.deposit{value: amount}(chainId);
        ghostDeposited += amount;
    }

    function withdraw(uint256 _chainSeed, uint256 _amount) external {
        uint256 chainId = _chain(_chainSeed);
        uint256 balance = MANAGER.chainBalance(chainId);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(_amount, 1, balance);
        vm.prank(admins[chainId]);
        MANAGER.withdraw(chainId, WITHDRAWAL_RECEIVER, amount);
        ghostWithdrawn += amount;
    }

    function chargeInteropFee(uint256 _chainSeed, uint256 _batchNumber, uint256 _units) external {
        uint256 chainId = _chain(_chainSeed);
        uint256 feePerUnit = MANAGER.feePerUnit();
        // Only charges the balance covers: an uncovered one reverts the execution and moves nothing.
        uint256 maxUnits = feePerUnit == 0 ? type(uint32).max : MANAGER.chainBalance(chainId) / feePerUnit;
        uint256 units = bound(_units, 0, maxUnits);
        vm.prank(zkChains[chainId]);
        MANAGER.chargeInteropFee(chainId, _batchNumber, units);
        ghostCharged += feePerUnit * units;
    }

    function setFeePerUnit(uint64 _feePerUnit) external {
        vm.prank(OWNER);
        MANAGER.setFeePerUnit(_feePerUnit);
    }

    function sweep() external {
        ghostSwept += MANAGER.accruedFees();
        MANAGER.sweep();
    }

    function totalChainBalances() external view returns (uint256 total) {
        for (uint256 i = 0; i < chainIds.length; ++i) {
            total += MANAGER.chainBalance(chainIds[i]);
        }
    }

    function _chain(uint256 _seed) internal view returns (uint256) {
        return chainIds[_seed % chainIds.length];
    }
}

contract InteropFeeManagerInvariantTest is Test {
    InteropFeeManager internal manager;
    InteropFeeManagerHandler internal handler;
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        address owner = makeAddr("owner");
        ChainRegistryStub registry = new ChainRegistryStub();
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

        uint256[] memory chainIds = new uint256[](3);
        (chainIds[0], chainIds[1], chainIds[2]) = (271, 272, 273);
        handler = new InteropFeeManagerHandler(manager, owner, registry, chainIds);
        targetContract(address(handler));
    }

    /// @dev The manager's ether always backs exactly the prepaid balances plus the fees not yet swept.
    function invariant_etherBacksLedgers() public view {
        assertEq(address(manager).balance, handler.totalChainBalances() + manager.accruedFees());
    }

    /// @dev Every charged wei is either still accrued or was swept, and only to the fee recipient.
    function invariant_chargedFeesAreAccruedOrSwept() public view {
        assertEq(handler.ghostCharged(), manager.accruedFees() + handler.ghostSwept());
        assertEq(recipient.balance, handler.ghostSwept());
    }

    /// @dev Every deposited wei is still prepaid, was charged, or was withdrawn by a chain admin.
    function invariant_depositsAreConserved() public view {
        assertEq(
            handler.ghostDeposited(),
            handler.totalChainBalances() + handler.ghostCharged() + handler.ghostWithdrawn()
        );
    }
}
