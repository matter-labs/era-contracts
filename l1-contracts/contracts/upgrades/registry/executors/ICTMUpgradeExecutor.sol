// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";

/// @title ICTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lifecycle surface of a `CTMUpgradeExecutor` other contracts read: the bound CTM
///         and the transition currently mid-lifecycle (see {docs/upgrade-stage-lifecycle.md}).
interface ICTMUpgradeExecutor {
    /// @notice Where the pending transition is in the three-stage lifecycle.
    /// @dev `None` means no transition is pending (stage 2 clears the slot).
    enum UpgradeStage {
        None,
        Prepared,
        Executed
    }

    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_TYPE_MANAGER() external view returns (IChainTypeManager);

    /// @notice The transition governance committed to with `stage0` and has not completed yet.
    function pendingTransition() external view returns (ICTMTransition);

    function pendingStage() external view returns (UpgradeStage);
}
