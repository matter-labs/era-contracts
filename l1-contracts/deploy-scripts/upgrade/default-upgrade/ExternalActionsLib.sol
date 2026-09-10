// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts-v4/utils/Strings.sol";

import {Call} from "contracts/governance/Common.sol";

/// @notice One governance (or admin) call a prepare emits that is NOT one of the three
///         `CTMUpgradeExecutor.stage0/1/2(transition)` calls — an action the on-chain upgrade
///         objects do not describe, declared with its phase, a label and the authority that
///         performs it, so the output can never imply the executor calls cover it.
/// @param phase The bundle it rides: `"0"`, `"1"`, `"2"` for the governance stages, `"admin"` for
///        separately emitted admin actions.
struct ExternalAction {
    string phase;
    string label;
    string authority;
    Call call;
}

/// @notice The prepare scripts' ledger of external actions (see {ExternalAction}). The base
///         pipelines emit exactly the executor calls; everything else a version script adds goes
///         through {declare}, which is what makes the emitted bundles auditable call by call.
library ExternalActionsLib {
    string internal constant PHASE_STAGE_0 = "0";
    string internal constant PHASE_STAGE_1 = "1";
    string internal constant PHASE_STAGE_2 = "2";
    string internal constant PHASE_ADMIN = "admin";

    struct Ledger {
        ExternalAction[] actions;
    }

    function declare(
        Ledger storage _ledger,
        string memory _phase,
        string memory _label,
        string memory _authority,
        Call memory _call
    ) internal {
        _ledger.actions.push(ExternalAction({phase: _phase, label: _label, authority: _authority, call: _call}));
    }

    /// @notice The declared calls of one phase, in declaration order.
    function callsForPhase(Ledger storage _ledger, string memory _phase) internal view returns (Call[] memory calls) {
        uint256 total = _ledger.actions.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total; ++i) {
            if (_samePhase(_ledger.actions[i].phase, _phase)) {
                ++count;
            }
        }
        calls = new Call[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < total; ++i) {
            if (_samePhase(_ledger.actions[i].phase, _phase)) {
                calls[cursor] = _ledger.actions[i].call;
                ++cursor;
            }
        }
    }

    /// @notice One human-readable line per declared action, for the prepare output's
    ///         `external_actions` list: `phase | label | target | selector | authority`.
    function describe(Ledger storage _ledger) internal view returns (string[] memory lines) {
        uint256 total = _ledger.actions.length;
        lines = new string[](total);
        for (uint256 i = 0; i < total; ++i) {
            ExternalAction storage action = _ledger.actions[i];
            lines[i] = string.concat(
                "phase ",
                action.phase,
                " | ",
                action.label,
                " | target ",
                Strings.toHexString(action.call.target),
                " | selector ",
                Strings.toHexString(uint256(uint32(bytes4(action.call.data))), 4),
                " | authority: ",
                action.authority
            );
        }
    }

    function _samePhase(string memory _a, string memory _b) private pure returns (bool) {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
