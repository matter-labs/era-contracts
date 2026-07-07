// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1InteropHandler} from "contracts/bridge/interfaces/IL1InteropHandler.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "contracts/core/message-root/IMessageRoot.sol";

/// @dev Minimal harness that exposes the internal `_getWithdrawalChain` so it can be exercised in isolation.
/// @dev Mocking is intentional here: `_getWithdrawalChain` only reads from the MessageRoot (v31 marker) and the
/// L1Nullifier (transient settlement layer), so we isolate it from the full withdrawal/NTV balance flow and assert
/// purely the chain-attribution logic.
contract L1AssetTrackerWithdrawalChainHarness is L1AssetTracker {
    constructor(
        address _bridgehub,
        address _nativeTokenVault,
        address _messageRoot
    ) L1AssetTracker(_bridgehub, _nativeTokenVault, _messageRoot) {}

    function exposed_getWithdrawalChain(uint256 _chainId) external view returns (uint256) {
        return _getWithdrawalChain(_chainId);
    }
}

/// @title L1AssetTrackerWithdrawalChainTest
/// @notice Tests for `L1AssetTracker._getWithdrawalChain`, the function that decides whether a withdrawal debits the
/// chain's balance or its settlement layer's balance. The key behaviour under test is that while a pre-existing chain
/// still holds the v31 placeholder (i.e. during the ecosystem upgrade window, before the chain runs its own diamond
/// upgrade), withdrawals are attributed to the chain itself instead of reverting — so withdrawals are NOT frozen
/// ecosystem-wide on upgrade.
contract L1AssetTrackerWithdrawalChainTest is Test {
    L1AssetTrackerWithdrawalChainHarness internal assetTracker;

    address internal bridgehub = makeAddr("bridgehub");
    address internal nativeTokenVault = makeAddr("nativeTokenVault");
    address internal messageRoot = makeAddr("messageRoot");
    address internal nullifier = makeAddr("nullifier");
    address internal interopHandler = makeAddr("interopHandler");

    uint256 internal constant CHAIN_ID = 271;
    // The chain in this test flipped to v31 at batch 100, so batch 101 is the first v31 batch.
    uint256 internal constant UPGRADE_BATCH = 101;
    // A settlement layer (e.g. Gateway) chain id, used for post-v31 batches.
    uint256 internal constant SETTLEMENT_LAYER = 999;

    function setUp() public {
        // The L1AssetTracker constructor resolves the nullifier from the NTV.
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(IL1NativeTokenVault.L1_NULLIFIER.selector),
            abi.encode(nullifier)
        );
        // `_getWithdrawalChain` reads the transient settlement layer from the interop handler, which it resolves
        // from the nullifier.
        vm.mockCall(
            nullifier,
            abi.encodeWithSelector(IL1Nullifier.l1InteropHandler.selector),
            abi.encode(interopHandler)
        );
        assetTracker = new L1AssetTrackerWithdrawalChainHarness(bridgehub, nativeTokenVault, messageRoot);
    }

    /// @dev Mocks the v31 marker stored on the MessageRoot for CHAIN_ID.
    function _mockV31Marker(uint256 _batchNumber) internal {
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector, CHAIN_ID),
            abi.encode(_batchNumber)
        );
    }

    /// @dev Mocks the transient settlement layer + batch number recorded by the interop handler during withdrawal proving.
    function _mockTransientSettlementLayer(uint256 _settlementLayer, uint256 _l2BatchNumber) internal {
        vm.mockCall(
            interopHandler,
            abi.encodeWithSelector(IL1InteropHandler.getTransientSettlementLayer.selector),
            abi.encode(_settlementLayer, _l2BatchNumber)
        );
    }

    /*//////////////////////////////////////////////////////////////
        Placeholder window: withdrawals continue, attributed to chain
    //////////////////////////////////////////////////////////////*/

    /// @notice While the placeholder is set, a withdrawal proven directly on L1 is attributed to the chain.
    function test_placeholder_settledOnL1_returnsChain() public {
        _mockV31Marker(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE);
        _mockTransientSettlementLayer(0, 42);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }

    /// @notice While the placeholder is set, even a withdrawal that carries a non-zero settlement layer (e.g. a
    /// pre-v31 batch that had settled on an old Gateway before the chain migrated to L1 for the upgrade) is attributed
    /// to the chain — pre-v31 batches are always the chain's responsibility. Critically, this no longer reverts.
    function test_placeholder_withSettlementLayer_returnsChain() public {
        _mockV31Marker(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE);
        _mockTransientSettlementLayer(SETTLEMENT_LAYER, 42);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }

    /// @notice During the placeholder window the result is always the chain, regardless of the proven settlement
    /// layer and batch number, because no post-v31 batch can exist for the chain yet.
    function testFuzz_placeholder_alwaysReturnsChain(uint256 _settlementLayer, uint256 _l2BatchNumber) public {
        _mockV31Marker(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE);
        _mockTransientSettlementLayer(_settlementLayer, _l2BatchNumber);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
        After marker is finalized: original attribution preserved
    //////////////////////////////////////////////////////////////*/

    /// @notice Once the marker is set, a withdrawal settled directly on L1 is attributed to the chain.
    function test_markerSet_settledOnL1_returnsChain() public {
        _mockV31Marker(UPGRADE_BATCH);
        _mockTransientSettlementLayer(0, UPGRADE_BATCH + 5);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }

    /// @notice Once the marker is set, a pre-v31 batch (batch number below the marker) is attributed to the chain.
    function test_markerSet_preV31Batch_returnsChain() public {
        _mockV31Marker(UPGRADE_BATCH);
        _mockTransientSettlementLayer(SETTLEMENT_LAYER, UPGRADE_BATCH - 1);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }

    /// @notice Once the marker is set, a post-v31 batch (at or above the marker) settled via a settlement layer is
    /// attributed to that settlement layer.
    function test_markerSet_postV31Batch_returnsSettlementLayer() public {
        _mockV31Marker(UPGRADE_BATCH);
        _mockTransientSettlementLayer(SETTLEMENT_LAYER, UPGRADE_BATCH);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), SETTLEMENT_LAYER);
    }

    /// @notice For chains added after the upgrade the marker defaults to 0, so all their batches are under v31 rules:
    /// settlement-layer batches are attributed to the settlement layer...
    function test_newChain_zeroMarker_settlementLayerBatch_returnsSettlementLayer() public {
        _mockV31Marker(0);
        _mockTransientSettlementLayer(SETTLEMENT_LAYER, 5);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), SETTLEMENT_LAYER);
    }

    /// @notice ...and L1-settled batches are attributed to the chain.
    function test_newChain_zeroMarker_l1Batch_returnsChain() public {
        _mockV31Marker(0);
        _mockTransientSettlementLayer(0, 5);

        assertEq(assetTracker.exposed_getWithdrawalChain(CHAIN_ID), CHAIN_ID);
    }
}
