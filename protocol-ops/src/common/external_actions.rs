//! The `external_actions` list of a prepare output: every governance or admin call the upgrade
//! objects do NOT describe, declared by the script that emits it.
//!
//! The Solidity side keeps these as structs (`ExternalActionsLib.Ledger`) and derives both halves
//! of its output from that one ledger — the executable governance bundle via `callsForPhase`, and
//! this list via `ExternalActionsLib.serialize`:
//!
//! ```toml
//! [[external_actions]]
//! phase = "governance"        # "governance" for the governance bundle, "admin" for admin ones
//! label = "hand the ecosystem ProxyAdmin to the bound core executor"
//! authority = "protocol governance"
//! target = "0x…"
//! value = "0"                 # decimal: the field is a uint256
//! data = "0x…"
//! ```
//!
//! Carrying the call itself rather than a rendering of it is what lets the merge check provenance
//! by identity (see `check_bundle_provenance`): every call of the governance bundle must BE one of
//! the governance phase's declared actions, one for one and in declared order ([`DeclaredCalls`],
//! which the verifier holds every registry package kind to as well). The one-line renderings reviewers read are produced by
//! [`ExternalAction::describe`] at the point of display.

use alloy::primitives::{Address, Bytes, U256};
use serde::{Deserialize, Serialize};

use crate::common::governance_calls::GovernanceCall;

/// The phase of an action riding the governance bundle (`ExternalActionsLib.PHASE_GOVERNANCE`).
pub const GOVERNANCE_PHASE: &str = "governance";

/// One declared external action.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExternalAction {
    pub phase: String,
    pub label: String,
    pub authority: String,
    pub target: Address,
    #[serde(with = "decimal_u256")]
    pub value: U256,
    pub data: Bytes,
}

impl ExternalAction {
    /// One action of the governance bundle.
    pub fn governance(
        label: impl Into<String>,
        authority: impl Into<String>,
        call: &GovernanceCall,
    ) -> Self {
        Self {
            phase: GOVERNANCE_PHASE.to_string(),
            label: label.into(),
            authority: authority.into(),
            target: call.target,
            value: call.value,
            data: call.data.clone().into(),
        }
    }

    /// Whether this action is the call `call` — the identity the merge's provenance check is
    /// built on.
    pub fn is_call(&self, call: &GovernanceCall) -> bool {
        self.target == call.target && self.value == call.value && self.data[..] == call.data[..]
    }

    /// `phase N | label | target 0x… | selector 0x… | authority: …` — the reviewer-facing line.
    pub fn describe(&self) -> String {
        let selector = &self.data[..self.data.len().min(4)];
        format!(
            "phase {} | {} | target {:#x} | selector 0x{} | authority: {}",
            self.phase,
            self.label,
            self.target,
            alloy::hex::encode(selector),
            self.authority,
        )
    }
}

/// How one bundle call stands against the governance-phase declarations.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Accounted {
    /// The call IS the declaration at this index of [`DeclaredCalls::actions`].
    Declared(usize),
    /// The call is a declared action, but every declaration of it already accounts for an
    /// earlier call.
    Repeat,
    /// No governance-phase declaration is this call.
    Undeclared,
}

/// Bundle calls held against the governance-phase declarations one for one: each call claims
/// the first unclaimed declaration it IS ([`ExternalAction::is_call`]). The calls are exactly the
/// declarations, in declared order, iff [`Self::is_exact`] — the shape
/// `ExternalActionsLib.callsForPhase` emits.
#[derive(Debug)]
pub struct DeclaredCalls<'a> {
    /// The governance-phase declarations, in declared order.
    pub actions: Vec<&'a ExternalAction>,
    /// One entry per call, in the order the calls were given.
    pub calls: Vec<Accounted>,
    /// Indices into `actions` that no call claimed.
    pub unclaimed: Vec<usize>,
    /// Whether the claimed declarations appear in declared order.
    pub in_order: bool,
}

impl<'a> DeclaredCalls<'a> {
    /// Accounts for `calls`, in order, against the governance-phase actions of `declared`.
    pub fn match_calls<'c>(
        calls: impl IntoIterator<Item = &'c GovernanceCall>,
        declared: &'a [ExternalAction],
    ) -> Self {
        let actions: Vec<&ExternalAction> = declared
            .iter()
            .filter(|action| action.phase == GOVERNANCE_PHASE)
            .collect();
        let mut claimed = vec![false; actions.len()];
        let mut last: Option<usize> = None;
        let mut in_order = true;
        let calls = calls
            .into_iter()
            .map(|call| {
                match (0..actions.len()).find(|&i| !claimed[i] && actions[i].is_call(call)) {
                    Some(i) => {
                        claimed[i] = true;
                        if last.is_some_and(|previous| previous > i) {
                            in_order = false;
                        }
                        last = Some(i);
                        Accounted::Declared(i)
                    }
                    None if actions.iter().any(|action| action.is_call(call)) => Accounted::Repeat,
                    None => Accounted::Undeclared,
                }
            })
            .collect();
        let unclaimed = (0..actions.len()).filter(|&i| !claimed[i]).collect();
        Self {
            actions,
            calls,
            unclaimed,
            in_order,
        }
    }

    /// The calls ARE the governance-phase declarations, one for one and in declared order.
    pub fn is_exact(&self) -> bool {
        self.in_order
            && self.unclaimed.is_empty()
            && self
                .calls
                .iter()
                .all(|account| matches!(account, Accounted::Declared(_)))
    }
}

/// `value` is a uint256 but a TOML integer is signed 64-bit, so it travels as a decimal string.
mod decimal_u256 {
    use alloy::primitives::U256;
    use serde::{Deserialize, Deserializer, Serializer};
    use std::str::FromStr;

    pub(super) fn serialize<S: Serializer>(value: &U256, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<U256, D::Error> {
        let raw = String::deserialize(deserializer)?;
        U256::from_str(&raw).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(target: u8, value: u64, data: &[u8]) -> GovernanceCall {
        GovernanceCall {
            target: Address::repeat_byte(target),
            value: U256::from(value),
            data: data.to_vec(),
        }
    }

    #[test]
    fn round_trips_through_toml() {
        let actions = vec![ExternalAction::governance(
            "hand the ecosystem ProxyAdmin to the bound core executor",
            "protocol governance",
            &call(0x11, 7, &[0xde, 0xad, 0xbe, 0xef, 0x01]),
        )];
        let encoded = toml::Value::try_from(&actions).expect("serialize");
        let decoded: Vec<ExternalAction> = encoded.try_into().expect("deserialize");
        assert_eq!(decoded.len(), 1);
        assert!(decoded[0].is_call(&call(0x11, 7, &[0xde, 0xad, 0xbe, 0xef, 0x01])));
        assert_eq!(decoded[0].phase, GOVERNANCE_PHASE);
    }

    /// The Solidity side writes `value` as a decimal string; a `0x`-prefixed one (what this
    /// module's own serializer never emits, but a hand-edited artifact might) still parses.
    #[test]
    fn parses_decimal_and_hex_values() {
        let table = r#"
            phase = "governance"
            label = "l"
            authority = "a"
            target = "0x0000000000000000000000000000000000000001"
            value = "255"
            data = "0x00"
        "#;
        let decimal: ExternalAction = toml::from_str(table).expect("decimal value");
        assert_eq!(decimal.value, U256::from(255));
        let hex: ExternalAction =
            toml::from_str(&table.replace("\"255\"", "\"0xff\"")).expect("hex value");
        assert_eq!(hex.value, U256::from(255));
    }

    #[test]
    fn describe_renders_the_selector_only() {
        let action = ExternalAction::governance(
            "accept ownership",
            "protocol governance",
            &call(0x22, 0, &[0x01, 0x02, 0x03, 0x04, 0xff]),
        );
        assert_eq!(
            action.describe(),
            "phase governance | accept ownership | target \
             0x2222222222222222222222222222222222222222 | selector 0x01020304 | authority: \
             protocol governance"
        );
    }

    /// A call that differs only in its calldata is not the declared action — the property the
    /// merge's provenance check rests on.
    #[test]
    fn identity_is_target_value_and_calldata() {
        let action = ExternalAction::governance("l", "a", &call(0x11, 1, &[0xaa]));
        assert!(action.is_call(&call(0x11, 1, &[0xaa])));
        assert!(!action.is_call(&call(0x11, 1, &[0xab])));
        assert!(!action.is_call(&call(0x11, 2, &[0xaa])));
        assert!(!action.is_call(&call(0x12, 1, &[0xaa])));
    }

    fn decl(calls: &[GovernanceCall]) -> Vec<ExternalAction> {
        calls
            .iter()
            .map(|c| ExternalAction::governance("l", "a", c))
            .collect()
    }

    #[test]
    fn identical_declarations_are_claimed_in_turn() {
        let a = call(0x11, 0, &[0xaa]);
        let declared = decl(&[a.clone(), a.clone()]);
        assert!(DeclaredCalls::match_calls([&a, &a], &declared).is_exact());
        let one = DeclaredCalls::match_calls([&a], &declared);
        assert_eq!(one.unclaimed, vec![1]);
        let three = DeclaredCalls::match_calls([&a, &a, &a], &declared);
        assert_eq!(three.calls[2], Accounted::Repeat);
    }

    #[test]
    fn a_repeat_is_told_apart_from_an_undeclared_call() {
        let (a, b) = (call(0x11, 0, &[0xaa]), call(0x22, 0, &[0xbb]));
        let declared = decl(std::slice::from_ref(&a));
        let account = DeclaredCalls::match_calls([&a, &a, &b], &declared);
        assert_eq!(
            account.calls,
            vec![
                Accounted::Declared(0),
                Accounted::Repeat,
                Accounted::Undeclared
            ]
        );
    }

    #[test]
    fn a_repeated_value_transfer_is_a_repeat() {
        let pay = call(0x33, 1_000, &[]);
        let declared = decl(std::slice::from_ref(&pay));
        let account = DeclaredCalls::match_calls([&pay, &pay], &declared);
        assert!(!account.is_exact());
        assert_eq!(account.calls[1], Accounted::Repeat);
    }

    #[test]
    fn interleaved_duplicates_out_of_order_are_caught() {
        let (a, b) = (call(0x11, 0, &[0xaa]), call(0x22, 0, &[0xbb]));
        let declared = decl(&[a.clone(), b.clone(), a.clone()]);
        let account = DeclaredCalls::match_calls([&a, &a, &b], &declared);
        assert!(account.unclaimed.is_empty());
        assert!(!account.in_order);
    }

    #[test]
    fn an_admin_declaration_accounts_for_nothing() {
        let a = call(0x11, 0, &[0xaa]);
        let mut declared = decl(std::slice::from_ref(&a));
        declared[0].phase = "admin".to_string();
        let account = DeclaredCalls::match_calls([&a], &declared);
        assert_eq!(account.calls, vec![Accounted::Undeclared]);
        assert!(account.actions.is_empty());
    }

    /// Exhaustively, over every pair of sequences of up to four calls from a two-call alphabet:
    /// the account is exact iff the calls ARE the declarations, in order.
    #[test]
    fn exact_iff_the_calls_are_the_declarations_in_order() {
        let alphabet = [call(0x11, 0, &[0xaa]), call(0x11, 1, &[0xaa])];
        let sequences: Vec<Vec<GovernanceCall>> = (0..=4usize)
            .flat_map(|len| {
                let alphabet = alphabet.clone();
                (0..(1usize << len)).map(move |mask| {
                    (0..len)
                        .map(|bit| alphabet[(mask >> bit) & 1].clone())
                        .collect()
                })
            })
            .collect();
        for declared in &sequences {
            let declarations = decl(declared);
            for calls in &sequences {
                let account = DeclaredCalls::match_calls(calls, &declarations);
                let equal = calls.len() == declared.len()
                    && calls.iter().zip(declared).all(|(c, d)| {
                        c.target == d.target && c.value == d.value && c.data == d.data
                    });
                assert_eq!(account.is_exact(), equal, "{declared:?} vs {calls:?}");
            }
        }
    }
}
