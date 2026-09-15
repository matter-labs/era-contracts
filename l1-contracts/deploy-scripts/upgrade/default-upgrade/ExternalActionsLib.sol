// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {Call} from "contracts/governance/Common.sol";

/// @notice One governance (or admin) call a prepare emits that is NOT one of the three
///         `EcosystemUpgradeExecutor.stage0/1/2(operation)` calls — an action the on-chain upgrade
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
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

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

    /// @notice The ledger as the prepare output's `external_actions` list: one TOML table per
    ///         declared action carrying the call itself — `target`, `value`, `data` — beside its
    ///         `phase`, `label` and `authority`.
    /// @dev Emitted from the same ledger {callsForPhase} builds the stage bundles from, which is
    ///      what lets `protocol-ops` hold a prepare output to an identity rather than a headcount:
    ///      every call of stage N must BE one of phase N's declared actions, target, value and
    ///      calldata alike (`check_bundle_provenance`). A prepare that composes a call it never
    ///      declared therefore fails the merge instead of shipping. Reviewer-facing one-line
    ///      renderings are produced where the list is displayed, from these same fields.
    /// @return entries One JSON object per action, in declaration order, for
    ///         `vm.serializeString(..., string[])` to nest as an array of tables.
    function serialize(Ledger storage _ledger) internal returns (string[] memory entries) {
        uint256 total = _ledger.actions.length;
        entries = new string[](total);
        for (uint256 i = 0; i < total; ++i) {
            ExternalAction storage action = _ledger.actions[i];
            string memory key = string.concat("external_action_", vm.toString(i));
            vm.serializeString(key, "phase", action.phase);
            vm.serializeString(key, "label", action.label);
            vm.serializeString(key, "authority", action.authority);
            vm.serializeAddress(key, "target", action.call.target);
            // Decimal string rather than a TOML integer: the field is a uint256 and a TOML
            // integer is signed 64-bit.
            vm.serializeString(key, "value", vm.toString(action.call.value));
            entries[i] = vm.serializeBytes(key, "data", action.call.data);
        }
    }

    function _samePhase(string memory _a, string memory _b) private pure returns (bool) {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
