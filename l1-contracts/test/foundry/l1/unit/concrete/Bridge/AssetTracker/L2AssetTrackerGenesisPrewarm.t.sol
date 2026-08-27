// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {AssetIdNotRegistered, MissingBaseTokenAssetId} from "contracts/common/L1ContractErrors.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Models the zksync-os bootloader's block-level asset-tracker prewarm against a
/// freshly-genesised chain, and pins the storage slot the genesis tool seeds to work around it.
///
/// From zksync-os v0.5.0 on, `prewarm_l1_postprocessing` runs a synthetic, immediately-rolled-back
/// `handleFinalizeBaseTokenBridgingOnL2(l1ChainId, 1)` as `L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR` at the
/// start of *every* block, purely to admit the mandatory L1-finalization preimages before any
/// transaction can exhaust its preimage-cache budget. It treats a revert as a fatal block error.
///
/// A fresh chain's genesis installs the tracker with code but no initialized storage — `initL2` runs
/// inside the genesis upgrade transaction, i.e. *after* block 1's prewarm — so without the seeded slot
/// the prewarm reverts and block 1 can never execute.
contract L2AssetTrackerGenesisPrewarmTest is Test {
    /// @dev The amount the bootloader's prewarm hardcodes. Non-zero on purpose: the tracker
    /// early-returns on a zero amount, which would defeat the preimage admission the prewarm exists
    /// for, so a zero-amount prewarm would never exercise the path this test covers.
    uint256 internal constant PREWARM_AMOUNT = 1;

    /// @dev Slot of `L2AssetTracker.BASE_TOKEN_ASSET_ID`, mirrored in the genesis tool as
    /// `L2_ASSET_TRACKER_BASE_TOKEN_ASSET_ID_SLOT` (tools/zksync-os-genesis-gen/src/consts.rs).
    uint256 internal constant BASE_TOKEN_ASSET_ID_SLOT = 205;

    /// @dev Placeholder written by the genesis tool; mirrors `GENESIS_PLACEHOLDER_BASE_TOKEN_ASSET_ID`.
    bytes32 internal constant GENESIS_PLACEHOLDER_ASSET_ID = bytes32(uint256(1));

    /// @dev Slot of `isAssetRegistered`, the mapping the second seeded slot keys into.
    uint256 internal constant IS_ASSET_REGISTERED_SLOT = 203;

    /// @dev Precomputed `keccak256(abi.encode(GENESIS_PLACEHOLDER_ASSET_ID, IS_ASSET_REGISTERED_SLOT))`,
    /// mirroring `L2_ASSET_TRACKER_PLACEHOLDER_ASSET_REGISTERED_SLOT` in the genesis tool. Pinned as a
    /// literal so a layout shift is caught by `test_seededSlotsArePinned` rather than silently tracking it.
    bytes32 internal constant GENESIS_PLACEHOLDER_ASSET_REGISTERED_SLOT =
        0xb3c459fcfa972435363277a54960f9947fdf75faf912b521fbcc6cd1c34ddc33;

    uint256 internal constant L1_CHAIN_ID = 1;

    L2AssetTracker internal tracker;

    /// @dev Stands the tracker up the way genesis does: code at the canonical address, storage
    /// untouched. The genesis proxy indirection is irrelevant here — the revert is decided by the
    /// implementation reading its own `BASE_TOKEN_ASSET_ID` slot.
    function setUp() public {
        deployCodeTo("L2AssetTracker.sol:L2AssetTracker", L2_ASSET_TRACKER_ADDR);
        tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
    }

    /// @notice Both slots the genesis tool seeds are where it thinks they are.
    /// @dev Guards the Rust-side constants against a silent storage-layout shift. Note the tracker
    /// inherits `PausableUpgradeable`, so its own state starts at slot 201 — not the 151 that
    /// zksync-os's vendored test fixture assumes.
    function test_seededSlotsArePinned() public {
        bytes32 sentinel = keccak256("sentinel asset id");
        vm.store(L2_ASSET_TRACKER_ADDR, bytes32(BASE_TOKEN_ASSET_ID_SLOT), sentinel);
        assertEq(tracker.BASE_TOKEN_ASSET_ID(), sentinel, "BASE_TOKEN_ASSET_ID is not at the pinned slot");

        assertEq(
            GENESIS_PLACEHOLDER_ASSET_REGISTERED_SLOT,
            keccak256(abi.encode(GENESIS_PLACEHOLDER_ASSET_ID, IS_ASSET_REGISTERED_SLOT)),
            "seeded isAssetRegistered slot does not match the mapping derivation"
        );
        vm.store(L2_ASSET_TRACKER_ADDR, GENESIS_PLACEHOLDER_ASSET_REGISTERED_SLOT, bytes32(uint256(1)));
        assertTrue(
            tracker.isAssetRegistered(GENESIS_PLACEHOLDER_ASSET_ID),
            "isAssetRegistered is not at the pinned slot"
        );
    }

    /// @notice Reproduces the failure: on unseeded genesis storage the prewarm reverts, which the
    /// bootloader escalates to a fatal block error, so block 1 never runs and `initL2` never happens.
    function test_prewarmRevertsOnUnseededGenesisStorage() public {
        assertEq(tracker.BASE_TOKEN_ASSET_ID(), bytes32(0), "genesis storage should start uninitialized");

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(MissingBaseTokenAssetId.selector);
        tracker.handleFinalizeBaseTokenBridgingOnL2(L1_CHAIN_ID, PREWARM_AMOUNT);
    }

    /// @notice Seeding the asset id *alone* is not enough, and this pins why.
    /// @dev A non-zero asset id stops the early return, so the prewarm runs the full inner path, whose
    /// first step requires the NTV to know the asset's origin chain. The genesis NTV has code but no
    /// initialized storage, so that lookup reads zero and the prewarm reverts one level deeper.
    function test_prewarmStillRevertsWithOnlyAssetIdSeeded() public {
        deployCodeTo("L2NativeTokenVaultZKOS.sol:L2NativeTokenVaultZKOS", L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.store(L2_ASSET_TRACKER_ADDR, bytes32(BASE_TOKEN_ASSET_ID_SLOT), GENESIS_PLACEHOLDER_ASSET_ID);

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, GENESIS_PLACEHOLDER_ASSET_ID));
        tracker.handleFinalizeBaseTokenBridgingOnL2(L1_CHAIN_ID, PREWARM_AMOUNT);
    }

    /// @notice The fix: with both slots seeded the prewarm completes on genesis state, so block 1 can
    /// execute and the genesis upgrade transaction gets to run.
    /// @dev The NTV is deliberately left undeployed: with `isAssetRegistered` seeded the inner path
    /// must return before consulting it, so this doubles as a canary — if a future change reintroduces
    /// an NTV call here, this fails with `call to non-contract address`. Leaving it out can only cause
    /// a spurious failure, never mask a real revert. `SystemContext` *is* deployed, because the path
    /// genuinely reads `currentSettlementLayerChainId()` (a plain getter over zeroed genesis storage).
    function test_prewarmSucceedsWithFullGenesisSeeding() public {
        deployCodeTo("SystemContext.sol:SystemContext", L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
        _seedGenesisPlaceholders();

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        tracker.handleFinalizeBaseTokenBridgingOnL2(L1_CHAIN_ID, PREWARM_AMOUNT);
    }

    /// @dev Mirrors exactly what `construct_additional_storage` writes for the tracker at genesis.
    function _seedGenesisPlaceholders() internal {
        vm.store(L2_ASSET_TRACKER_ADDR, bytes32(BASE_TOKEN_ASSET_ID_SLOT), GENESIS_PLACEHOLDER_ASSET_ID);
        vm.store(L2_ASSET_TRACKER_ADDR, GENESIS_PLACEHOLDER_ASSET_REGISTERED_SLOT, bytes32(uint256(1)));
    }

    /// @notice The placeholder is not load-bearing beyond genesis: `initL2` overwrites it with the
    /// chain's real asset id, which is why a chain-agnostic genesis may seed an arbitrary non-zero one.
    function test_initL2OverwritesSeededPlaceholder() public {
        _seedGenesisPlaceholders();

        bytes32 realAssetId = keccak256("real base token asset id");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tracker.initL2(L1_CHAIN_ID, realAssetId);

        assertEq(tracker.BASE_TOKEN_ASSET_ID(), realAssetId, "initL2 must overwrite the genesis placeholder");
        assertEq(tracker.L1_CHAIN_ID(), L1_CHAIN_ID, "initL2 must still set the L1 chain id");
    }
}
