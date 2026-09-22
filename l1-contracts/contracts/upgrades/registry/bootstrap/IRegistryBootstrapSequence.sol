// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Call} from "../../../governance/Common.sol";

/// @notice One governance call of the bootstrap edge, with the label and authority a reviewer
///         reads it under.
/// @param label What the call does, in the runbook's words.
/// @param authority Who has to send it.
/// @param call The call itself, in the shape the governance bundles carry.
struct BootstrapAction {
    string label;
    string authority;
    Call call;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The read surface of the bootstrap edge's call sequence: the ordered governance calls of
///         each stage, and the completion gate that terminates stage 2.
interface IRegistryBootstrapSequence {
    /// @notice The edge this sequence describes.
    function MIGRATION() external view returns (address);

    /// @notice The ecosystem inventory the edge's core leg applies.
    function CORE_TRANSITION() external view returns (address);

    /// @notice The stage-0 calls, in execution order.
    function stage0Actions() external view returns (BootstrapAction[] memory);

    /// @notice The stage-1 calls, in execution order.
    function stage1Actions() external view returns (BootstrapAction[] memory);

    /// @notice The stage-2 calls, in execution order; the last one is `validateApplied()` on this
    ///         contract.
    function stage2Actions() external view returns (BootstrapAction[] memory);

    /// @notice Reverts unless BOTH domains of the edge are applied.
    function validateApplied() external view;
}
