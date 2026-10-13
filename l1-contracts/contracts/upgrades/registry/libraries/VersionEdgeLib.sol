// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {SemVer} from "../../../common/libraries/SemVer.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA} from "../../../common/Config.sol";
import {
    NewProtocolMajorVersionNotZero,
    PreviousProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "../../ZkSyncUpgradeErrors.sol";
import {
    PatchCannotCarryL2Upgrade,
    TransitionDeadlineBeforeUpgrade,
    TransitionDeadlineZero
} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The version-shape and schedule rules every committed CTM edge obeys, checked when the
///         edge's object is constructed — before governance can commit an edge that would bump the
///         CTM and then revert on every chain. Shared by `CTMTransition` and
///         `RegistryBootstrapMigration`.
library VersionEdgeLib {
    /// @notice Reverts unless the edge `_oldVersion -> _newVersion` with this schedule and L2 side
    ///         is one every chain can execute.
    /// @param _oldVersion The packed version the edge departs from.
    /// @param _newVersion The packed version the edge moves to.
    /// @param _oldVersionDeadline Until when `_oldVersion` stays usable once the edge is committed.
    /// @param _upgradeTimestamp From when chains may cross the edge.
    /// @param _hasL2Side Whether the edge carries an L2 upgrade transaction.
    /// @return isPatch Whether the edge only moves the patch component.
    function requireValidEdge(
        uint256 _oldVersion,
        uint256 _newVersion,
        uint256 _oldVersionDeadline,
        uint256 _upgradeTimestamp,
        bool _hasL2Side
    ) internal pure returns (bool isPatch) {
        // A committed edge only ever moves the version forward — the same rule chains enforce at
        // execution and the CTM enforces when it commits.
        if (_newVersion <= _oldVersion) {
            revert ProtocolVersionTooSmall(_oldVersion, _newVersion);
        }
        // A zero deadline expires the departing version the moment the edge is committed, which
        // stops every chain still on it from committing batches before any of them can upgrade.
        // The relative check below cannot catch it: a zeroed schedule satisfies `0 >= 0`.
        // `upgradeTimestamp` has no such lower bound — zero there legitimately means chains may
        // upgrade as soon as the edge is committed. Only the ZERO deadline is refused: any nonzero
        // value passes, including one already in the past, which disables the departing version
        // immediately. That is permitted — an incident may call for it — merely discouraged; zero
        // is refused because it is far likelier a defaulted field than a decision.
        if (_oldVersionDeadline == 0) {
            revert TransitionDeadlineZero();
        }
        // The old version must stay usable at least until chains are allowed to upgrade,
        // otherwise the schedule disables the old protocol before the new one is reachable.
        if (_oldVersionDeadline < _upgradeTimestamp) {
            revert TransitionDeadlineBeforeUpgrade(_oldVersionDeadline, _upgradeTimestamp);
        }

        // Patch component deliberately ignored: these checks are about the major.minor edge.
        // slither-disable-next-line unused-return
        (uint32 oldMajor, uint32 oldMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_oldVersion));
        // slither-disable-next-line unused-return
        (uint32 newMajor, uint32 newMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_newVersion));
        // The same version-shape rules `BaseZkSyncUpgrade._setNewProtocolVersion` applies per chain.
        // Watch out: there are plans to move ZKsync OS to major 1 to distinguish it from Era.
        // When that lands, this pair of checks and `_setNewProtocolVersion` change together.
        if (oldMajor != 0) {
            revert PreviousProtocolMajorVersionNotZero();
        }
        if (newMajor != 0) {
            revert NewProtocolMajorVersionNotZero();
        }
        // Safe: majors are both zero and the packed new version is strictly greater, so the
        // minor cannot have decreased.
        uint256 minorDelta = newMinor - oldMinor;
        if (minorDelta > MAX_ALLOWED_MINOR_VERSION_DELTA) {
            revert ProtocolVersionMinorDeltaTooBig(MAX_ALLOWED_MINOR_VERSION_DELTA, minorDelta);
        }

        isPatch = oldMinor == newMinor;
        // `BaseZkSyncUpgrade._setL2SystemContractUpgrade` refuses an L2 protocol upgrade transaction
        // on a patch (`PatchCantSetUpgradeTxn`), and a patch deliberately does NOT require an
        // earlier L2 upgrade to be finalized first — a pending one must survive the patch untouched.
        if (isPatch && _hasL2Side) {
            revert PatchCannotCarryL2Upgrade();
        }
    }
}
