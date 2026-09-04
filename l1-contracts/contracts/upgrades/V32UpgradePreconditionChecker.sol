// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IUpgradePreconditionChecker} from "./IUpgradePreconditionChecker.sol";
import {UPGRADE_PRECONDITION_CHECKER_MAGIC} from "./UpgradePreconditionCheckerConfig.sol";
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
/// @title V32UpgradePreconditionChecker
/// @notice Checks v32 upgrade scheduling prerequisites; see {protocol-docs/upgrade-scheduling.md}.
contract V32UpgradePreconditionChecker is IUpgradePreconditionChecker {
    /// @notice Registry of per-chain priority-op lower bounds.
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
    function checkUpgradePreconditions(
        uint256, // _chainId
        address _zkChain
    ) external view {
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
    /// @dev Handles zero addresses for direct callers; ServerNotifier resolves registered chains first.
    function previewUpgradePreconditions(
        uint256, // _chainId
        address _zkChain
    ) external view returns (bytes4[] memory failed) {
        if (_zkChain == address(0)) {
            failed = new bytes4[](1);
            failed[0] = ZKChainNotRegistered.selector;
            return failed;
        }

        bytes4[] memory collected = new bytes4[](3);
        uint256 count;
        if (!_baseTokenBackfilled(_zkChain)) {
            collected[count] = BaseTokenPreV31TotalSupplyNotSet.selector;
            ++count;
        }
        if (!_lowerBoundRecorded(_zkChain)) {
            collected[count] = LowerBoundNotRecorded.selector;
            ++count;
        }
        if (!_priorityQueueReady(_zkChain)) {
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
