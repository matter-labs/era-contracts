// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1ChainAssetHandlerDev} from "contracts/dev-contracts/L1ChainAssetHandlerDev.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {MigrationPaused, ChainTypeManagerNotRegistered, NotCTMOwner} from "contracts/common/L1ContractErrors.sol";

/// @notice The migration pause of `ChainAssetHandlerBase`, which is TWO pauses on two authorities:
///
///         - the ECOSYSTEM pause (`pauseMigration`/`unpauseMigration`, owner only) — incident
///           control that stops every chain regardless of its CTM;
///         - a PER-CTM pause (`pauseCTMMigration`/`unpauseCTMMigration`) written by that CTM's
///           own owner, which during an upgrade is its bound `CTMUpgradeExecutor`.
///
///         `migrationPausedFor(ctm)` is the OR of the two, and the gate on `bridgeBurn`/
///         `bridgeMint` asks it about the CTM the migrating chain belongs to. Splitting the state
///         this way means one CTM's upgrade neither blocks nor unblocks another's chains — the
///         reason a chain may only migrate between settlement layers under its own CTM
///         (`SLHasDifferentCTM`) is the same reason the pause is keyed by CTM.
///
/// @dev Authority is DERIVED, not stored: a caller qualifies by being the current owner of a CTM
///      this ecosystem registered. There is no allowlist to maintain, so replacing an executor
///      cannot strand the ability to pause. See {docs/upgrade-stage-lifecycle.md}, section 4.3.
/// @dev Runs against a real `L1ChainAssetHandler` deployed directly (its constructor sets the
///      owner). The Bridgehub is mocked for the two lookups the pause surface makes —
///      `chainTypeManagerIsRegistered` and `ctmAssetIdToAddress` — because the pause logic
///      touches nothing else of it; the migration flow itself is covered by the integration suites.
contract L1ChainAssetHandlerMigrationPauseTest is Test {
    L1ChainAssetHandlerDev internal handler;

    address internal owner = makeAddr("owner");
    address internal bridgehub = makeAddr("bridgehub");
    address internal ctmA = makeAddr("ctmA");
    address internal ctmB = makeAddr("ctmB");
    address internal executorA = makeAddr("ctmExecutorA");
    address internal executorB = makeAddr("ctmExecutorB");
    address internal stranger = makeAddr("stranger");

    bytes32 internal assetA = keccak256("ctmA-asset");
    bytes32 internal assetB = keccak256("ctmB-asset");

    function setUp() public {
        // The Dev variant only re-enables migrations (`CHAIN_MIGRATIONS_ENABLED` is false in this
        // release), which is what makes the `bridgeBurn` pause gate reachable at all: the
        // release-level ban is checked first and would otherwise mask it.
        handler = new L1ChainAssetHandlerDev(owner, bridgehub);
        assertEq(handler.owner(), owner, "fixture: the constructor sets the owner");
        assertFalse(handler.migrationPaused(), "fixture: the ecosystem pause starts clear");

        // Both CTMs are registered, each owned by its own executor.
        _registerCTM(ctmA, executorA, assetA);
        _registerCTM(ctmB, executorB, assetB);
    }

    /// @dev MOCKED: only the two Bridgehub getters the pause surface reads.
    function _registerCTM(address _ctm, address _ctmOwner, bytes32 _assetId) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.chainTypeManagerIsRegistered, (_ctm)), abi.encode(true));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.ctmAssetIdToAddress, (_assetId)), abi.encode(_ctm));
        vm.mockCall(_ctm, abi.encodeCall(IOwnable.owner, ()), abi.encode(_ctmOwner));
    }

    function _pauseCTM(address _caller, address _ctm) internal {
        vm.prank(_caller);
        handler.pauseCTMMigration(_ctm);
    }

    function _unpauseCTM(address _caller, address _ctm) internal {
        vm.prank(_caller);
        handler.unpauseCTMMigration(_ctm);
    }

    // ─────────────────────────── the per-CTM pause ───────────────────────────

    function test_pauseCTMMigration_byThatCTMsOwner() public {
        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.PausedCTMMigration(ctmA, executorA);
        _pauseCTM(executorA, ctmA);

        assertTrue(handler.ctmMigrationPaused(ctmA));
        assertTrue(handler.migrationPausedFor(ctmA));
        assertFalse(handler.migrationPaused(), "a CTM pause must not set the ecosystem pause");

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.UnpausedCTMMigration(ctmA, executorA);
        _unpauseCTM(executorA, ctmA);
        assertFalse(handler.migrationPausedFor(ctmA));
    }

    /// @dev THE point of keying by CTM: two upgrades running at once do not share a flag, so
    ///      neither can lift the other's pause. This is the case the previous single-flag design
    ///      could not express.
    function test_oneCTMsPauseIsIndependentOfAnothers() public {
        _pauseCTM(executorA, ctmA);
        _pauseCTM(executorB, ctmB);

        _unpauseCTM(executorA, ctmA);
        assertFalse(handler.migrationPausedFor(ctmA), "A's own upgrade completed");
        assertTrue(handler.migrationPausedFor(ctmB), "B's pause must survive A's completion");
    }

    function test_revertWhen_pausingAnotherCTM() public {
        // A's executor owns A, not B.
        vm.expectRevert(abi.encodeWithSelector(NotCTMOwner.selector, executorA, ctmB));
        _pauseCTM(executorA, ctmB);
        assertFalse(handler.migrationPausedFor(ctmB));
    }

    function test_revertWhen_pausingByAStranger() public {
        vm.expectRevert(abi.encodeWithSelector(NotCTMOwner.selector, stranger, ctmA));
        _pauseCTM(stranger, ctmA);

        // The ecosystem owner is not implicitly a CTM's owner either: its route is pauseMigration.
        vm.expectRevert(abi.encodeWithSelector(NotCTMOwner.selector, owner, ctmA));
        _pauseCTM(owner, ctmA);
    }

    /// @dev Registration is checked as well as ownership: otherwise any contract could claim to be
    ///      a CTM and write a pause row nothing would ever read.
    function test_revertWhen_pausingAnUnregisteredCTM() public {
        address foreign = makeAddr("foreignCtm");
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.chainTypeManagerIsRegistered, (foreign)),
            abi.encode(false)
        );
        vm.mockCall(foreign, abi.encodeCall(IOwnable.owner, ()), abi.encode(stranger));

        vm.expectRevert(abi.encodeWithSelector(ChainTypeManagerNotRegistered.selector, foreign));
        _pauseCTM(stranger, foreign);
    }

    /// @dev Authority is read live, so a CTM handed to a new owner (executor succession) moves the
    ///      ability to pause with it — no allowlist to update, and the predecessor loses it at once.
    function test_authorityFollowsCTMOwnership() public {
        _pauseCTM(executorA, ctmA);

        address successor = makeAddr("successorExecutor");
        vm.mockCall(ctmA, abi.encodeCall(IOwnable.owner, ()), abi.encode(successor));

        vm.expectRevert(abi.encodeWithSelector(NotCTMOwner.selector, executorA, ctmA));
        _unpauseCTM(executorA, ctmA);

        _unpauseCTM(successor, ctmA);
        assertFalse(handler.migrationPausedFor(ctmA));
    }

    // ─────────────────────────── the ecosystem pause ───────────────────────────

    function test_ecosystemPause_stopsEveryCTM() public {
        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.PausedMigration(owner);
        vm.prank(owner);
        handler.pauseMigration();

        assertTrue(handler.migrationPausedFor(ctmA));
        assertTrue(handler.migrationPausedFor(ctmB));
        assertFalse(handler.ctmMigrationPaused(ctmA), "the per-CTM rows stay untouched");
    }

    function test_revertWhen_ecosystemPauseByNonOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(executorA);
        handler.pauseMigration();
        assertFalse(handler.migrationPaused());
    }

    /// @dev The separation that matters for incident response: a CTM's own upgrade completing
    ///      cannot lift a pause the ecosystem owner set.
    function test_ctmUnpauseCannotLiftTheEcosystemPause() public {
        vm.prank(owner);
        handler.pauseMigration();
        _pauseCTM(executorA, ctmA);

        _unpauseCTM(executorA, ctmA);
        assertTrue(handler.migrationPausedFor(ctmA), "the ecosystem pause is not a CTM's to lift");

        vm.prank(owner);
        handler.unpauseMigration();
        assertFalse(handler.migrationPausedFor(ctmA));
    }

    /// @dev And the converse: the ecosystem owner lifting its own pause does not resume a CTM
    ///      that is mid-upgrade.
    function test_ecosystemUnpauseLeavesACTMPauseInPlace() public {
        vm.prank(owner);
        handler.pauseMigration();
        _pauseCTM(executorA, ctmA);

        vm.prank(owner);
        handler.unpauseMigration();
        assertTrue(handler.migrationPausedFor(ctmA), "A is still mid-upgrade");
        assertFalse(handler.migrationPausedFor(ctmB), "B was never paused");
    }

    function test_pauseIsIdempotent() public {
        _pauseCTM(executorA, ctmA);
        _pauseCTM(executorA, ctmA);
        assertTrue(handler.migrationPausedFor(ctmA));

        _unpauseCTM(executorA, ctmA);
        _unpauseCTM(executorA, ctmA);
        assertFalse(handler.migrationPausedFor(ctmA));
    }

    // ─────────────────────── effect on the guarded flow ───────────────────────

    /// @dev The gate resolves the CTM from the migrating chain's asset id, so a pause on ctmA
    ///      refuses A's migrations while leaving B's to fail later for their own reasons (here
    ///      the release-level migration ban, which is not what this test is about).
    function test_bridgeBurn_revertWhen_itsOwnCTMIsPaused() public {
        address assetRouter = makeAddr("assetRouter");
        // MOCKED: the two Bridgehub getters `setAddresses` copies.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(makeAddr("messageRoot")));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.prank(owner);
        handler.setAddresses();

        _pauseCTM(executorA, ctmA);

        vm.expectRevert(MigrationPaused.selector);
        vm.prank(assetRouter);
        handler.bridgeBurn(1, 0, assetA, address(0), hex"");

        // ctmB is not paused, so its migration clears the pause gate and fails further in, on
        // the migration data this test does not construct.
        vm.prank(assetRouter);
        vm.expectRevert();
        handler.bridgeBurn(1, 0, assetB, address(0), hex"");

        // And once A's pause lifts, A's migration clears the gate the same way.
        _unpauseCTM(executorA, ctmA);
        vm.prank(assetRouter);
        vm.expectRevert();
        handler.bridgeBurn(1, 0, assetA, address(0), hex"");
    }
}
