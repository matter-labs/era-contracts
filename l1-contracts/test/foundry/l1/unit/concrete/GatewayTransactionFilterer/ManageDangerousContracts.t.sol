// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    GatewayTransactionFilterer,
    MIN_ALLOWED_ADDRESS
} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AlreadyDangerousContract, NotDangerousContract} from "contracts/common/L1ContractErrors.sol";

contract ManageDangerousContractsTest is GatewayTransactionFiltererTest {
    event DangerousContractAdded(address indexed contractAddress);
    event DangerousContractRemoved(address indexed contractAddress);

    address internal randomUser = makeAddr("randomUser");

    // ============ Initialization Tests ============

    function test_initialize_marksCreate2FactoryAsDangerous() public view {
        // The Create2Factory should be in the dangerous contracts list from initialization
        assertTrue(
            transactionFiltererProxy.dangerousContracts(ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR),
            "Create2Factory should be marked as dangerous on initialization"
        );
    }

    function test_initialize_emitsDangerousContractAddedForCreate2Factory() public {
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(IBridgehubBase(bridgehub), assetRouter);

        vm.expectEmit(true, false, false, false);
        emit DangerousContractAdded(ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR);

        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, owner)
        );
    }

    // ============ addDangerousContract Tests ============

    function test_addDangerousContract_marksContractAsDangerous() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.prank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);

        assertTrue(
            transactionFiltererProxy.dangerousContracts(dangerousAddr),
            "Contract should be marked as dangerous"
        );
    }

    function test_addDangerousContract_emitsEvent() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit DangerousContractAdded(dangerousAddr);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);
    }

    function test_addDangerousContract_revertsIfNotOwner() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        transactionFiltererProxy.addDangerousContract(dangerousAddr);
    }

    function test_addDangerousContract_revertsIfAlreadyDangerous() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.startPrank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);

        vm.expectRevert(abi.encodeWithSelector(AlreadyDangerousContract.selector, dangerousAddr));
        transactionFiltererProxy.addDangerousContract(dangerousAddr);
        vm.stopPrank();
    }

    // ============ removeDangerousContract Tests ============

    function test_removeDangerousContract_unmarksContract() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.startPrank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);
        transactionFiltererProxy.removeDangerousContract(dangerousAddr);
        vm.stopPrank();

        assertFalse(
            transactionFiltererProxy.dangerousContracts(dangerousAddr),
            "Contract should no longer be marked as dangerous"
        );
    }

    function test_removeDangerousContract_emitsEvent() public {
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.startPrank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);

        vm.expectEmit(true, false, false, false);
        emit DangerousContractRemoved(dangerousAddr);
        transactionFiltererProxy.removeDangerousContract(dangerousAddr);
        vm.stopPrank();
    }

    function test_removeDangerousContract_revertsIfNotOwner() public {
        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        transactionFiltererProxy.removeDangerousContract(ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR);
    }

    function test_removeDangerousContract_revertsIfNotDangerous() public {
        address notDangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(NotDangerousContract.selector, notDangerousAddr));
        transactionFiltererProxy.removeDangerousContract(notDangerousAddr);
    }

    // ============ isTransactionAllowed – Dangerous Contract Tests ============

    function test_isTransactionAllowed_blocksDangerousContractForNonWhitelisted() public {
        // Add a contract above MIN_ALLOWED_ADDRESS as dangerous
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);
        vm.prank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            dangerousAddr,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertFalse(isAllowed, "Non-whitelisted sender should be blocked from calling a dangerous contract");
    }

    function test_isTransactionAllowed_allowsDangerousContractForWhitelisted() public {
        // Add a contract above MIN_ALLOWED_ADDRESS as dangerous
        address dangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 100);

        vm.startPrank(owner);
        transactionFiltererProxy.addDangerousContract(dangerousAddr);
        transactionFiltererProxy.grantWhitelist(randomUser);
        vm.stopPrank();

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            dangerousAddr,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertTrue(isAllowed, "Whitelisted sender should be allowed to call a dangerous contract");
    }

    function test_isTransactionAllowed_blocksCreate2FactoryForNonWhitelisted() public view {
        // Deterministic Create2 factory is marked dangerous on initialization and is above MIN_ALLOWED_ADDRESS
        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertFalse(isAllowed, "Non-whitelisted sender should be blocked from calling Create2Factory");
    }

    function test_isTransactionAllowed_allowsCreate2FactoryForWhitelisted() public {
        vm.prank(owner);
        transactionFiltererProxy.grantWhitelist(randomUser);

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertTrue(isAllowed, "Whitelisted sender should be allowed to call Create2Factory");
    }

    function test_isTransactionAllowed_highAddressStillAllowedIfNotDangerous() public view {
        // A high address that is NOT in dangerousContracts should still be freely accessible
        address highAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 999);

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            highAddr,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertTrue(isAllowed, "High address not in dangerousContracts should be allowed");
    }

    function test_isTransactionAllowed_dangerousContractTakesPrecedenceOverHighAddress() public {
        // Even if a contract is above MIN_ALLOWED_ADDRESS, being in dangerousContracts blocks it
        address highDangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 500);
        vm.prank(owner);
        transactionFiltererProxy.addDangerousContract(highDangerousAddr);

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            highDangerousAddr,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertFalse(
            isAllowed,
            "Dangerous contract above MIN_ALLOWED_ADDRESS should still be blocked for non-whitelisted sender"
        );
    }

    function test_isTransactionAllowed_afterRemovingDangerousContract_highAddressAllowed() public {
        address highDangerousAddr = address(uint160(MIN_ALLOWED_ADDRESS) + 500);

        vm.startPrank(owner);
        transactionFiltererProxy.addDangerousContract(highDangerousAddr);
        transactionFiltererProxy.removeDangerousContract(highDangerousAddr);
        vm.stopPrank();

        bool isAllowed = transactionFiltererProxy.isTransactionAllowed(
            randomUser,
            highDangerousAddr,
            0,
            0,
            hex"12345678",
            address(0)
        );

        assertTrue(isAllowed, "After removal from dangerousContracts, high address should be freely accessible");
    }
}
