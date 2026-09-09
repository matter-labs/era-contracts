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
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

/// @notice The migration pause of `ChainAssetHandlerBase`: ONE flag, written by the owner or by
///         any address the owner registered as an upgrade pauser (`setUpgradePauser`). There is no
///         per-pauser hold and no counter — an upgrade executor calls the same
///         `pauseMigration` / `unpauseMigration` governance calls. See
///         {docs/upgrade-stage-lifecycle.md}, section 4.3.
/// @dev The tests below deliberately pin the CONSEQUENCE of a single flag: any authorized caller
///      can lift a pause any other authorized caller set, so coordinating overlapping upgrades and
///      incident pauses is governance's responsibility rather than something this contract
///      enforces.
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

    function _pause(address _caller) internal {
        vm.prank(_caller);
        handler.pauseMigration();
    }

    function _unpause(address _caller) internal {
        vm.prank(_caller);
        handler.unpauseMigration();
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

    // ─────────────────────────────── authorization ───────────────────────────────

    function test_pauseMigration_byOwner() public {
        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.PausedMigration(owner);
        _pause(owner);
        assertTrue(handler.migrationPaused());

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.UnpausedMigration(owner);
        _unpause(owner);
        assertFalse(handler.migrationPaused());
    }

    /// @dev A registered pauser drives the SAME calls the owner does — that is the whole point of
    ///      the allowlist: stage 0 pauses and stage 2 unpauses through governance's own entrypoints.
    function test_pauseMigration_byRegisteredPauser() public {
        _register(pauserA);

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.PausedMigration(pauserA);
        _pause(pauserA);
        assertTrue(handler.migrationPaused());

        vm.expectEmit(true, true, true, true, address(handler));
        emit IChainAssetHandlerBase.UnpausedMigration(pauserA);
        _unpause(pauserA);
        assertFalse(handler.migrationPaused());
    }

    function test_revertWhen_pauseByUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, stranger));
        _pause(stranger);
        assertFalse(handler.migrationPaused());

        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, stranger));
        _unpause(stranger);
    }

    function test_revertWhen_pauseByRevokedPauser() public {
        _register(pauserA);
        _pause(pauserA);
        vm.prank(owner);
        handler.setUpgradePauser(pauserA, false);

        // Revocation is immediate, and it does not strand the pause: the owner still holds it.
        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, pauserA));
        _unpause(pauserA);
        assertTrue(handler.migrationPaused());

        _unpause(owner);
        assertFalse(handler.migrationPaused());
    }

    /// @dev Setting the flag twice is a no-op rather than a revert: a lifecycle that retries its
    ///      stage 0 must not be blocked by a pause that is already in place.
    function test_pauseAndUnpause_areIdempotent() public {
        _register(pauserA);
        _pause(pauserA);
        _pause(pauserA);
        assertTrue(handler.migrationPaused());

        _unpause(pauserA);
        _unpause(pauserA);
        assertFalse(handler.migrationPaused());
    }

    // ─────────────────── one flag: the coordination consequence ───────────────────

    /// @dev EXPLICIT accepted behavior. Two overlapping upgrades share one flag, so the first to
    ///      finish unpauses migrations while the second is still running. This is not defended
    ///      against in the contract: it protects against accident, not against malicious
    ///      governance, which controls the executors anyway. Governance must therefore not run
    ///      overlapping upgrade lifecycles — see {docs/upgrade-stage-lifecycle.md}.
    function test_onePauserUnpauseLiftsAnothersPause() public {
        _register(pauserA);
        _register(pauserB);

        _pause(pauserA);
        _pause(pauserB);
        assertTrue(handler.migrationPaused());

        _unpause(pauserA);
        assertFalse(handler.migrationPaused(), "one flag: A's unpause lifts the pause B still needs");
    }

    /// @dev The same consequence in the other direction: an authorized executor can lift the
    ///      owner's own pause, so an incident pause must not be left to coexist with an upgrade.
    function test_pauserUnpauseLiftsTheOwnersPause() public {
        _register(pauserA);
        _pause(owner);

        _unpause(pauserA);
        assertFalse(handler.migrationPaused(), "one flag: a pauser's unpause lifts the owner's pause");
    }

    // ─────────────────────────────── effect on the guarded flow ───────────────────────────────

    /// @dev The flag is honored by `whenMigrationsNotPaused` whoever set it: the migration
    ///      entrypoint refuses while paused, and admits the call once unpaused (the flow then
    ///      fails later, on the release-level migration ban, which is not what this test is about).
    function test_bridgeBurn_revertWhen_paused() public {
        address assetRouter = makeAddr("assetRouter");
        // MOCKED: the two Bridgehub getters `setAddresses` copies; nothing else of the Bridgehub
        // is touched before the pause gate.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(makeAddr("messageRoot")));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.prank(owner);
        handler.setAddresses();

        _register(pauserA);
        _pause(pauserA);

        vm.expectRevert(MigrationPaused.selector);
        vm.prank(assetRouter);
        handler.bridgeBurn(1, 0, bytes32(0), address(0), hex"");

        _unpause(pauserA);
        // Unpausing opens the pause gate, but production migrations remain disabled.
        vm.expectRevert(ChainMigrationsDisabled.selector);
        vm.prank(assetRouter);
        handler.bridgeBurn(1, 0, bytes32(0), address(0), hex"");
    }
}
