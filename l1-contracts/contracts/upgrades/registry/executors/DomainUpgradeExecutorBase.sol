// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {Unauthorized} from "../../../common/L1ContractErrors.sol";

/// @title DomainUpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The coordinator binding both domain executors share. Each domain supplies what applying
///         its leg of an operation means.
abstract contract DomainUpgradeExecutorBase is UpgradeExecutorBase, IDomainUpgradeExecutor {
    /// @inheritdoc IDomainUpgradeExecutor
    address public coordinator;

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @param _initialOwner The governance the executor answers to.
    /// @param _coordinator The coordinator it starts bound to; zero leaves it detached.
    constructor(address _initialOwner, address _coordinator) UpgradeExecutorBase(_initialOwner) {
        coordinator = _coordinator;
    }

    /// @inheritdoc IDomainUpgradeExecutor
    function setCoordinator(address _coordinator) external onlyOwner {
        emit CoordinatorChanged(coordinator, _coordinator);
        coordinator = _coordinator;
    }
}
