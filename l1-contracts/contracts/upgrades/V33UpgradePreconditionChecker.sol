// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IUpgradePreconditionChecker, UPGRADE_PRECONDITION_CHECKER_MAGIC} from "./IUpgradePreconditionChecker.sol";
import {IPriorityOpLowerBound} from "./IPriorityOpLowerBound.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {
    BaseTokenPreV31TotalSupplyNotSet,
    LowerBoundNotRecorded,
    PriorityQueueNotReady,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {ZKChainNotRegistered} from "../core/bridgehub/L1BridgehubErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title V33UpgradePreconditionChecker
/// @notice Scheduling-time counterpart of the prerequisite triple `V32UpgradeZKsyncOS.upgrade`
/// enforces at execution time (the v31 base-token backfill flag, a recorded priority-op lower
/// bound, and a priority queue processed up to that bound), reusing the same errors so a
/// scheduling failure reads identically to the execution failure it front-runs.
/// See {protocol-docs/upgrade-scheduling.md}.
/// @dev Named after the release the repo's upgrade-env fixtures exercise (v32 -> v33), while the
/// sibling upgrade contract carries the production transition's target version (v31 -> v32);
/// {protocol-docs/upgrade-scheduling.md} explains the mismatch.
contract V33UpgradePreconditionChecker is IUpgradePreconditionChecker {
    /// @notice Standalone registry of per-chain priority-op lower bounds — the same instance the
    /// release's `V32UpgradeZKsyncOS` embeds.
    IPriorityOpLowerBound public immutable PRIORITY_OP_LOWER_BOUND;

    constructor(IPriorityOpLowerBound _priorityOpLowerBound) {
        if (address(_priorityOpLowerBound) == address(0)) {
            revert ZeroAddress();
        }
        PRIORITY_OP_LOWER_BOUND = _priorityOpLowerBound;
    }

    /// @inheritdoc IUpgradePreconditionChecker
    function getSupportsUpgradePreconditionCheckerMagic() external pure returns (bytes32) {
        return UPGRADE_PRECONDITION_CHECKER_MAGIC;
    }

    /// @inheritdoc IUpgradePreconditionChecker
    function checkUpgradePreconditions(uint256, address _zkChain) external view {
        if (_zkChain == address(0)) {
            revert ZKChainNotRegistered();
        }
        if (!_baseTokenBackfilled(_zkChain)) {
            revert BaseTokenPreV31TotalSupplyNotSet();
        }
        if (!_lowerBoundRecorded(_zkChain)) {
            revert LowerBoundNotRecorded();
        }
        if (!_priorityQueueReady(_zkChain)) {
            revert PriorityQueueNotReady();
        }
    }

    /// @inheritdoc IUpgradePreconditionChecker
    function previewUpgradePreconditions(
        uint256,
        address _zkChain
    ) external view returns (bytes4[] memory failed) {
        if (_zkChain == address(0)) {
            failed = new bytes4[](1);
            failed[0] = ZKChainNotRegistered.selector;
            return failed;
        }

        bytes4[] memory collected = new bytes4[](3);
        uint256 count = 0;
        if (!_baseTokenBackfilled(_zkChain)) {
            collected[count] = BaseTokenPreV31TotalSupplyNotSet.selector;
            ++count;
        }
        if (!_lowerBoundRecorded(_zkChain)) {
            collected[count] = LowerBoundNotRecorded.selector;
            ++count;
        } else if (!_priorityQueueReady(_zkChain)) {
            // The queue check is only meaningful against a recorded bound (an unrecorded bound
            // reads as zero and passes trivially), so it is reported only once one exists.
            collected[count] = PriorityQueueNotReady.selector;
            ++count;
        }

        failed = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            failed[i] = collected[i];
        }
    }

    function _baseTokenBackfilled(address _zkChain) internal view returns (bool) {
        return IGetters(_zkChain).baseTokenSupportsTotalSupply();
    }

    function _lowerBoundRecorded(address _zkChain) internal view returns (bool) {
        return PRIORITY_OP_LOWER_BOUND.recorded(_zkChain);
    }

    function _priorityQueueReady(address _zkChain) internal view returns (bool) {
        return IGetters(_zkChain).getFirstUnprocessedPriorityTx() >= PRIORITY_OP_LOWER_BOUND.lowerBound(_zkChain);
    }
}
