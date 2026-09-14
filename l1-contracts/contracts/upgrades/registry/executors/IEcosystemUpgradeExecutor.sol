// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";

/// @title IEcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle surface of the coordinating `EcosystemUpgradeExecutor` other contracts
///         and tooling read: the operation mid-lifecycle and its stage. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IEcosystemUpgradeExecutor {
    /// @notice Where the pending operation is in the three-stage lifecycle.
    /// @dev `None` means no operation is pending (stage 2 and abandonment clear the slot).
    enum UpgradeStage {
        None,
        Prepared,
        Executed
    }

    /// @notice The operation governance prepared with `stage0` and has not completed yet.
    function pendingOperation() external view returns (IEcosystemUpgradeOperation);

    function pendingStage() external view returns (UpgradeStage);
}
