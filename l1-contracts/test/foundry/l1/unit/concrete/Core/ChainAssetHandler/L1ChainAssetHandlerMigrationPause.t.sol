// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    MigrationPaused,
    ChainMigrationsDisabled,
    NotUpgradePauser,
    UpgradePauseAlreadyHeld,
    UpgradePauseNotHeld,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

/// @notice The migration pause of `ChainAssetHandlerBase` as two composable sources: the owner's
///         own flag (`pauseMigration` / `unpauseMigration`) and per-pauser HOLDS taken by
///         owner-registered upgrade pausers (`acquireMigrationPause` / `releaseMigrationPause`).
///         `migrationPaused()` is the OR of both; a pauser can only ever release its own hold and
///         the owner can clear a stuck one. See {docs/upgrade-stage-lifecycle.md}, section 4.3.
/// @dev Runs against a real `L1ChainAssetHandler` deployed directly (its constructor sets the
///      owner). The pause surface touches no other contract, so the Bridgehub is a bare address —
///      except in the one `bridgeBurn` test, where the two Bridgehub getters `setAddresses` reads
///      are mocked so the migration entrypoint can be reached; that test isolates the pause gate
///      from the migration flow itself, which the integration suites cover.
contract L1ChainAssetHandlerMigrationPauseTest is Test {
    L1ChainAssetHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal bridgehub = makeAddr("bridgehub");
    address internal pauserA = makeAddr("ctmExecutorA");
    address internal pauserB = makeAddr("ctmExecutorB");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        handler = new L1ChainAssetHandler(owner, bridgehub);
        assertEq(handler.owner(), owner, "fixture: the constructor sets the owner");
        assertFalse(handler.migrationPaused(), "fixture: migrations start unpaused");
    }

    function _register(address _pauser) internal {
        vm.prank(owner);
        handler.setUpgradePauser(_pauser, true);
    }

    function _acquire(address _pauser) internal {
        vm.prank(_pauser);
        handler.acquireMigrationPause();
    }

    function _release(address _pauser) internal {
        vm.prank(_pauser);
        handler.releaseMigrationPause();
    }

    function _assertHold(address _pauser, bool _held, uint256 _holds) internal view {
        assertEq(handler.upgradePauseHeld(_pauser), _held, "unexpected hold state");
        assertEq(handler.upgradePauseHolds(), _holds, "unexpected hold count");
    }

    // ─────────────────────────────── registration ───────────────────────────────

    function test_setUpgradePauser_registersAndRevokes() public {
        assertFalse(handler.isUpgradePauser(pauserA));

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.UpgradePauserSet(pauserA, true);
        vm.prank(owner);
        handler.setUpgradePauser(pauserA, true);
        assertTrue(handler.isUpgradePauser(pauserA), "registration must be recorded");

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.UpgradePauserSet(pauserA, false);
        vm.prank(owner);
        handler.setUpgradePauser(pauserA, false);
        assertFalse(handler.isUpgradePauser(pauserA), "revocation must be recorded");
    }

    function test_revertWhen_setUpgradePauserByStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        handler.setUpgradePauser(pauserA, true);
        assertFalse(handler.isUpgradePauser(pauserA));
    }

    function test_revertWhen_setUpgradePauserForZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(owner);
        handler.setUpgradePauser(address(0), true);
    }

    // ─────────────────────────────── acquire / release ───────────────────────────────

    function test_acquireMigrationPause_takesTheHoldAndPauses() public {
        _register(pauserA);

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.MigrationPauseAcquired(pauserA);
        _acquire(pauserA);

        _assertHold(pauserA, true, 1);
        assertTrue(handler.migrationPaused(), "a hold must pause migrations");
    }

    function test_revertWhen_acquireByUnregisteredPauser() public {
        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, stranger));
        vm.prank(stranger);
        handler.acquireMigrationPause();
        _assertHold(stranger, false, 0);
        assertFalse(handler.migrationPaused());

        // The owner is not implicitly a pauser either: the owner's route is `pauseMigration`.
        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, owner));
        vm.prank(owner);
        handler.acquireMigrationPause();
    }

    function test_revertWhen_acquireTwice() public {
        _register(pauserA);
        _acquire(pauserA);

        // One hold per pauser: a second acquire would let one release leave a phantom count.
        vm.expectRevert(abi.encodeWithSelector(UpgradePauseAlreadyHeld.selector, pauserA));
        vm.prank(pauserA);
        handler.acquireMigrationPause();
        _assertHold(pauserA, true, 1);
    }

    function test_releaseMigrationPause_releasesOwnHoldAndUnpauses() public {
        _register(pauserA);
        _acquire(pauserA);

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.MigrationPauseReleased(pauserA);
        _release(pauserA);

        _assertHold(pauserA, false, 0);
        assertFalse(handler.migrationPaused(), "the last hold released must unpause");
    }

    function test_revertWhen_releaseWithoutHold() public {
        _register(pauserA);

        vm.expectRevert(abi.encodeWithSelector(UpgradePauseNotHeld.selector, pauserA));
        vm.prank(pauserA);
        handler.releaseMigrationPause();

        // Releasing is gated on the HOLD, not on the allowlist, so a stranger fails the same way.
        vm.expectRevert(abi.encodeWithSelector(UpgradePauseNotHeld.selector, stranger));
        vm.prank(stranger);
        handler.releaseMigrationPause();
    }

    function test_revertWhen_releasingAnotherPausersHold() public {
        _register(pauserA);
        _register(pauserB);
        _acquire(pauserA);

        // B holds nothing; A's hold is not B's to release.
        vm.expectRevert(abi.encodeWithSelector(UpgradePauseNotHeld.selector, pauserB));
        vm.prank(pauserB);
        handler.releaseMigrationPause();
        _assertHold(pauserA, true, 1);
        assertTrue(handler.migrationPaused());
    }

    /// @dev A pauser de-registered mid-lifecycle (a retired executor) can still let go of what it
    ///      holds, so de-registration never strands a pause.
    function test_release_worksAfterDeregistration() public {
        _register(pauserA);
        _acquire(pauserA);
        vm.prank(owner);
        handler.setUpgradePauser(pauserA, false);

        // It cannot take a NEW hold any more...
        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, pauserA));
        vm.prank(pauserA);
        handler.acquireMigrationPause();

        // ...but it can release the one it has.
        _release(pauserA);
        _assertHold(pauserA, false, 0);
        assertFalse(handler.migrationPaused());
    }

    // ─────────────────────────────── owner recovery ───────────────────────────────

    function test_clearMigrationPauseHold_ownerReleasesAStuckHold() public {
        _register(pauserA);
        _acquire(pauserA);

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.MigrationPauseReleased(pauserA);
        vm.prank(owner);
        handler.clearMigrationPauseHold(pauserA);

        _assertHold(pauserA, false, 0);
        assertFalse(handler.migrationPaused());
    }

    function test_revertWhen_clearMigrationPauseHoldByStranger() public {
        _register(pauserA);
        _acquire(pauserA);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        handler.clearMigrationPauseHold(pauserA);
        _assertHold(pauserA, true, 1);
    }

    function test_revertWhen_clearMigrationPauseHoldOfNonHolder() public {
        vm.expectRevert(abi.encodeWithSelector(UpgradePauseNotHeld.selector, pauserA));
        vm.prank(owner);
        handler.clearMigrationPauseHold(pauserA);
    }

    // ─────────────────────────────── composition ───────────────────────────────

    function test_overlappingHolds_oneReleaseKeepsMigrationsPaused() public {
        _register(pauserA);
        _register(pauserB);
        _acquire(pauserA);
        _acquire(pauserB);
        assertEq(handler.upgradePauseHolds(), 2);

        _release(pauserA);
        _assertHold(pauserA, false, 1);
        assertTrue(handler.upgradePauseHeld(pauserB), "the other upgrade's hold must stay");
        assertTrue(handler.migrationPaused(), "one upgrade's completion must not lift another's pause");

        _release(pauserB);
        _assertHold(pauserB, false, 0);
        assertFalse(handler.migrationPaused());
    }

    function test_ownerPauseAndHold_releasingTheHoldKeepsTheOwnerPause() public {
        vm.prank(owner);
        handler.pauseMigration();
        _register(pauserA);
        _acquire(pauserA);
        assertTrue(handler.migrationPaused());

        _release(pauserA);
        assertTrue(handler.migrationPaused(), "the owner's pause is not a pauser's to lift");
        _assertHold(pauserA, false, 0);

        vm.prank(owner);
        handler.unpauseMigration();
        assertFalse(handler.migrationPaused());
    }

    function test_ownerUnpauseWithAHold_keepsMigrationsPaused() public {
        vm.prank(owner);
        handler.pauseMigration();
        _register(pauserA);
        _acquire(pauserA);

        vm.prank(owner);
        handler.unpauseMigration();
        assertTrue(handler.migrationPaused(), "a hold outlives the owner's unpause");
        _assertHold(pauserA, true, 1);

        _release(pauserA);
        assertFalse(handler.migrationPaused());
    }

    function test_ownerPauseAndUnpause_doNotTouchHolds() public {
        _register(pauserA);
        _acquire(pauserA);

        vm.prank(owner);
        handler.pauseMigration();
        _assertHold(pauserA, true, 1);
        vm.prank(owner);
        handler.unpauseMigration();
        _assertHold(pauserA, true, 1);
        assertTrue(handler.migrationPaused());
    }

    /// @dev The hold count is exactly the number of distinct holders: every registered pauser
    ///      acquires once, and migrations unpause only when the last one has released.
    function testFuzz_holdCountTracksDistinctHolders(uint8 _pauserCount) public {
        uint256 count = bound(_pauserCount, 1, 16);
        address[] memory pausers = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            pausers[i] = makeAddr(string(abi.encodePacked("pauser", i)));
            _register(pausers[i]);
            _acquire(pausers[i]);
            assertEq(handler.upgradePauseHolds(), i + 1);
        }
        assertTrue(handler.migrationPaused());

        for (uint256 i = 0; i < count; ++i) {
            _release(pausers[i]);
            assertEq(handler.upgradePauseHolds(), count - i - 1);
            assertEq(handler.migrationPaused(), i + 1 < count, "paused exactly while a hold remains");
        }
    }

    // ─────────────────────────────── effect on the guarded flow ───────────────────────────────

    /// @dev A hold is honored by `whenMigrationsNotPaused` exactly like the owner's flag: the
    ///      migration entrypoint refuses while any hold is in place, and admits the call once the
    ///      hold is released (the flow then fails later, on the migration data, which is not what
    ///      this test is about).
    function test_bridgeBurn_revertWhen_pausedByAHold() public {
        address assetRouter = makeAddr("assetRouter");
        // MOCKED: the two Bridgehub getters `setAddresses` copies; nothing else of the Bridgehub
        // is touched before the pause gate.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(makeAddr("messageRoot")));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.prank(owner);
        handler.setAddresses();

        _register(pauserA);
        _acquire(pauserA);

        vm.expectRevert(MigrationPaused.selector);
        vm.prank(assetRouter);
        handler.bridgeBurn(1, 0, bytes32(0), address(0), hex"");

        _release(pauserA);
        // Releasing the hold opens the pause gate, but production migrations remain disabled.
        vm.expectRevert(ChainMigrationsDisabled.selector);
        vm.prank(assetRouter);
        handler.bridgeBurn(1, 0, bytes32(0), address(0), hex"");
    }
}
