// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, console, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    L2_ASSET_TRACKER,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_CHAIN_ASSET_HANDLER,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_MESSAGE_ROOT,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {MAX_TOKEN_BALANCE} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {AssetAlreadyRegistered, AssetIdNotRegistered} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2UtilsBase} from "../l2-tests-in-l1-context/L2UtilsBase.sol";

import {Unauthorized, BaseTokenPreV31TotalSupplyNotSet} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

import {LogFinder} from "../utils/LogFinder.sol";

abstract contract L2AssetTrackerTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

    function test_handleInitiateBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("NativeToken", "NTV", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 amount = 7;

        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(address(token));
        uint256 balanceBefore = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceBefore, MAX_TOKEN_BALANCE, "Native token should be initialized on registration");

        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        uint256 balanceAfter = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceAfter, balanceBefore - amount, "Native token chain balance should decrease after withdrawal");
    }

    function test_handleFinalizeBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyToken", "LGC", 18);
        address l1Token = makeAddr("legacy_l1_token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        uint256 amount = 11;

        // An unregistered foreign asset must be rejected by handleFinalizeBridgingOnL2.
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleFinalizeBridgingOnL2(L1_CHAIN_ID, assetId, amount, L1_CHAIN_ID, address(token));
    }

    function test_handleFinalizeBaseTokenBridgingOnL2() public {
        // Test handling base token bridging into L2
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;
        uint256 mockedTotalSupply = 1000;

        // Mock base token asset ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Mock L1 chain ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);

        // Set initial chain balance (should be 0 for incoming tokens)
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(uint256(0));

        // Mock origin chain ID for base token (L1)
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // Mock totalSupply on L2_BASE_TOKEN_SYSTEM_CONTRACT (needed for foreign token total supply calculation)
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(mockedTotalSupply)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertFalse(tracker.isAssetRegistered(baseTokenAssetId), "Asset should not be registered before call");

        // Call as BaseTokenHolder (onlyBaseTokenHolderOrL2BaseToken modifier)
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // ---- Outcome assertions ----

        // chainBalance: base token's origin is L1, so the block.chainid branch is not taken; balance stays 0.
        assertEq(
            tracker.chainBalance(block.chainid, baseTokenAssetId),
            0,
            "Chain balance should remain 0 for foreign tokens"
        );

        // totalSuccessfulDepositsFromL1: incremented by amount (fromChainId == L1, settlement layer == L1).
        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");

        // _registerLegacyTokenIfNeeded was triggered on first contact: registration + supply snapshot set.
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId), "Asset should be registered after call");
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(savedAmount, mockedTotalSupply, "totalPreV31TotalSupply.amount should equal mocked totalSupply");
    }

    /// @notice On Era, L2BaseTokenEra.mint() calls handleFinalizeBaseTokenBridgingOnL2 directly
    /// (msg.sender = L2_BASE_TOKEN_SYSTEM_CONTRACT). This must be allowed by access control.
    function test_handleFinalizeBaseTokenBridgingOnL2_calledByL2BaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;
        uint256 mockedTotalSupply = 1000;

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(mockedTotalSupply)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        uint256 chainBalanceBefore = tracker.chainBalance(block.chainid, baseTokenAssetId);
        assertFalse(tracker.isAssetRegistered(baseTokenAssetId), "Asset should not be registered before call");

        // Call as L2BaseToken (the Era flow: L2BaseTokenEra.mint() → asset tracker)
        vm.prank(address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // ---- Outcome assertions ----

        // chainBalance: base token's origin is L1, so the block.chainid branch in
        // _handleFinalizeBridgingOnL2Inner is not taken; the balance must remain unchanged.
        assertEq(
            tracker.chainBalance(block.chainid, baseTokenAssetId),
            chainBalanceBefore,
            "Chain balance should remain unchanged for foreign-origin base token"
        );

        // totalSuccessfulDepositsFromL1: incremented by amount (fromChainId == L1, settlement layer == L1).
        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");

        // _registerLegacyTokenIfNeeded was triggered on first contact: registration + supply snapshot set.
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId), "Asset should be registered after call");
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(savedAmount, mockedTotalSupply, "totalPreV31TotalSupply.amount should equal mocked totalSupply");
    }

    /// @notice A random address must not be able to call handleFinalizeBaseTokenBridgingOnL2.
    function test_handleFinalizeBaseTokenBridgingOnL2_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(1, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  registerBaseTokenDuringUpgrade
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies that registerBaseTokenDuringUpgrade registers the base token correctly.
    function test_registerBaseTokenDuringUpgrade_registersBaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        // Set BASE_TOKEN_ASSET_ID (the function reads it internally)
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Verify not registered yet
        assertFalse(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should not be registered before call"
        );

        // Expect BaseTokenRegisteredDuringUpgrade event
        vm.expectEmit(true, false, false, false, L2_ASSET_TRACKER_ADDR);
        emit IL2AssetTracker.BaseTokenRegisteredDuringUpgrade(baseTokenAssetId);

        // Call as ComplexUpgrader (onlyUpgrader)
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();

        // Verify registered
        assertTrue(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should be registered after call"
        );

        // Verify totalPreV31TotalSupply was set to {isSaved: true, amount: 0}
        (bool isSaved, uint256 amount) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(amount, 0, "totalPreV31TotalSupply.amount should be 0");
    }

    /// @notice Verifies that registerBaseTokenDuringUpgrade reverts if already registered.
    function test_registerBaseTokenDuringUpgrade_revertIfAlreadyRegistered() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Pre-register the asset
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("isAssetRegistered(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(true);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AssetAlreadyRegistered.selector, baseTokenAssetId));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    /// @notice Verifies that only the ComplexUpgrader can call registerBaseTokenDuringUpgrade.
    function test_registerBaseTokenDuringUpgrade_revertUnauthorized() public {
        vm.prank(RAND_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, RAND_ADDRESS));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    function test_handleFinalizeBaseTokenBridgingOnL2_succeedsWhileBackfillPending() public {
        bytes32 baseTokenAssetId = keccak256("zkos_base_token_pending_backfill");
        uint256 l1ChainId = 1;

        // Use the real ZKsync OS base token: its `totalSupply()` reverts while the pre-V31
        // supply has not been backfilled, so no mock is needed for the behaviour under test.
        vm.etch(address(L2_BASE_TOKEN_SYSTEM_CONTRACT), address(new L2BaseTokenZKOS()).code);

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("needBaseTokenTotalSupplyBackfill()").checked_write(true);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // Pin down the precondition the fix relies on: while the backfill is pending, the real
        // base token's `totalSupply()` genuinely reverts with `BaseTokenPreV31TotalSupplyNotSet`.
        // This is the exact call `_needToForceSetAssetMigrationOnL2` makes, so without the fix the
        // finalization below reverts with this very error instead of recording the deposit.
        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        IERC20(address(L2_BASE_TOKEN_SYSTEM_CONTRACT)).totalSupply();

        // Register the base token exactly as the V31 upgrade does for an existing chain.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();

        // Settle on L1 so the deposit is accounted (same mock the sibling base-token tests use).
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);

        // The asset migration number is 0 (never set), which is exactly the path that reached the
        // reverting `totalSupply()` read before the fix; the finalization must now succeed.
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, 300);

        assertEq(
            _readTotalSuccessfulDepositsFromL1(baseTokenAssetId) - depositsBefore,
            300,
            "base-token deposit should be recorded while the supply is pending backfill"
        );
    }
}
