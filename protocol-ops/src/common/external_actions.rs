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
//! label = "bind the coordinator to the CTM executor"
//! authority = "protocol governance"
//! target = "0x…"
//! value = "0"                 # decimal: the field is a uint256
//! data = "0x…"
//! ```
//!
//! Carrying the call itself rather than a rendering of it is what lets the merge check provenance
//! by identity (see `check_bundle_provenance`): every call of the governance bundle must BE one of
//! the governance phase's declared actions. The one-line renderings reviewers read are produced by
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
            "bind the coordinator to the CTM executor",
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
}
