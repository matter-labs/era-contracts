// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Call} from "../../../governance/Common.sol";

/// @notice One governance call of the bootstrap edge, with the label and authority a reviewer
///         reads it under.
/// @param label What the call does, in the runbook's words.
/// @param authority Who has to send it.
/// @param call The call itself, in the shape the governance bundle carries.
struct BootstrapAction {
    string label;
    string authority;
    Call call;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The read surface of the bootstrap edge's call sequence: the ordered governance calls of
///         its one bundle, ending in the edge's completion check.
interface IRegistryBootstrapSequence {
    /// @notice The edge this sequence describes.
    function MIGRATION() external view returns (address);

    /// @notice The Core-domain transition the edge's core leg applies.
    function CORE_TRANSITION() external view returns (address);

    /// @notice The bootstrap bundle's calls, in execution order. Governance executes them as one
    ///         bundle, so any failing call — the closing completion check included — reverts the
    ///         whole edge.
    function actions() external view returns (BootstrapAction[] memory);
}
