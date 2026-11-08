// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    CallMode,
    IEraMaintenanceTransactionFilterer
} from "contracts/transactionFilterer/interfaces/IEraMaintenanceTransactionFilterer.sol";

import {EraMaintenanceTransactionFiltererTest} from "./_EraMaintenanceTransactionFilterer_Shared.t.sol";

contract ConfigurationTest is EraMaintenanceTransactionFiltererTest {
    address internal l2Contract = makeAddr("l2Contract");
    bytes4 internal constant SELECTOR = bytes4(keccak256("someFunction()"));

    function test_setCallMode() public {
        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.CallModeSet(CallMode.WITHDRAWALS_ONLY);
        vm.prank(owner);
        filterer.setCallMode(CallMode.WITHDRAWALS_ONLY);
        assertEq(uint256(filterer.callMode()), uint256(CallMode.WITHDRAWALS_ONLY));

        vm.prank(owner);
        filterer.setCallMode(CallMode.ALLOW_ALL);
        assertEq(uint256(filterer.callMode()), uint256(CallMode.ALLOW_ALL));
    }

    function test_setExempt() public {
        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.ExemptSet(user, true);
        vm.prank(owner);
        filterer.setExempt(user, true);
        assertTrue(filterer.exempt(user));

        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.ExemptSet(user, false);
        vm.prank(owner);
        filterer.setExempt(user, false);
        assertFalse(filterer.exempt(user));
    }

    function test_setDepositCaps() public {
        bytes32[] memory assetIds = new bytes32[](2);
        assetIds[0] = tokenAssetId;
        assetIds[1] = baseTokenAssetId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = TOKEN_CAP;
        caps[1] = 0;

        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.DepositCapSet(tokenAssetId, TOKEN_CAP);
        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.DepositCapSet(baseTokenAssetId, 0);
        vm.prank(owner);
        filterer.setDepositCaps(assetIds, caps);

        assertEq(filterer.depositCap(tokenAssetId), TOKEN_CAP);
        assertEq(filterer.depositCap(baseTokenAssetId), 0);
    }

    function test_revertWhen_depositCapsLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, 2, 1));
        vm.prank(owner);
        filterer.setDepositCaps(new bytes32[](2), new uint256[](1));
    }

    function test_setAllowedTxHash() public {
        bytes32 txHash = keccak256("tx");
        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.AllowedTxHashSet(txHash, true);
        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, true);
        assertTrue(filterer.allowedTxHashes(txHash));

        vm.prank(owner);
        filterer.setAllowedTxHash(txHash, false);
        assertFalse(filterer.allowedTxHashes(txHash));
    }

    function test_setWithdrawalFunction() public {
        vm.expectEmit(true, true, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.WithdrawalFunctionSet(l2Contract, SELECTOR, true);
        vm.prank(owner);
        filterer.setWithdrawalFunction(l2Contract, SELECTOR, true);
        assertTrue(filterer.withdrawalFunctions(l2Contract, SELECTOR));

        vm.prank(owner);
        filterer.setWithdrawalFunction(l2Contract, SELECTOR, false);
        assertFalse(filterer.withdrawalFunctions(l2Contract, SELECTOR));
    }

    function test_setLegacyBridge() public {
        vm.expectEmit(true, false, false, true, address(filterer));
        emit IEraMaintenanceTransactionFilterer.LegacyBridgeSet(lidoL1Bridge, true);
        vm.prank(owner);
        filterer.setLegacyBridge(lidoL1Bridge, true);
        assertTrue(filterer.legacyBridges(lidoL1Bridge));

        vm.prank(owner);
        filterer.setLegacyBridge(lidoL1Bridge, false);
        assertFalse(filterer.legacyBridges(lidoL1Bridge));
    }

    function test_revertWhen_notOwner() public {
        vm.startPrank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setCallMode(CallMode.WITHDRAWALS_ONLY);
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setExempt(user, true);
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setDepositCaps(new bytes32[](0), new uint256[](0));
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setAllowedTxHash(bytes32(0), true);
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setWithdrawalFunction(l2Contract, SELECTOR, true);
        vm.expectRevert("Ownable: caller is not the owner");
        filterer.setLegacyBridge(lidoL1Bridge, true);
        vm.stopPrank();
    }
}
