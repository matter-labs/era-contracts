//! ABI helpers for the `Call[]` payloads embedded in our governance TOMLs.
//!
//! Every prepare command, and the merged package, writes the governance bundle as:
//!
//! ```toml
//! [governance_calls]
//! calls = "0x…"   # abi.encode(Call[])
//! ```
//!
//! `Call` matches the Solidity struct in `contracts/governance/Common.sol`:
//! `struct Call { address target; uint256 value; bytes data; }`. This module
//! gives us encode / decode / merge for `Call[]` so protocol-ops can fold
//! multiple per-script governance TOMLs into a single merged TOML before
//! handing them off to `upgrade-governance`.

use alloy::hex;
use alloy::primitives::{Address, U256};
use alloy::sol;
use alloy::sol_types::SolValue;
use anyhow::Context;
use serde::Deserialize;

/// The `[governance_calls]` table: the one bundle governance executes. Unknown keys are refused,
/// so a package still carrying per-stage keys fails to load instead of having them ignored.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GovernanceCallsTable {
    /// `abi.encode(Call[])` as `0x…` hex.
    pub calls: String,
}

sol! {
    /// Mirror of `struct Call { address target; uint256 value; bytes data; }`
    /// in `contracts/governance/Common.sol`.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }
}

#[derive(Clone, Debug)]
pub struct GovernanceCall {
    pub target: Address,
    pub value: U256,
    pub data: Vec<u8>,
}

/// `abi.encode(Call[])`.
pub fn encode_calls(calls: &[GovernanceCall]) -> Vec<u8> {
    let sol_calls: Vec<Call> = calls
        .iter()
        .map(|c| Call {
            target: c.target,
            value: c.value,
            data: c.data.clone().into(),
        })
        .collect();
    sol_calls.abi_encode()
}

/// `abi.decode(Call[])` from a `0x`-prefixed hex string.
pub fn decode_calls(hex_str: &str) -> anyhow::Result<Vec<GovernanceCall>> {
    let trimmed = hex_str.trim_start_matches("0x");
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let raw = hex::decode(trimmed).context("invalid governance calls hex")?;
    let sol_calls = <Vec<Call>>::abi_decode(&raw).context("Call[] ABI decode")?;
    Ok(sol_calls
        .into_iter()
        .map(|c| GovernanceCall {
            target: c.target,
            value: c.value,
            data: c.data.to_vec(),
        })
        .collect())
}

/// Concatenated re-encoding of multiple `Call[]` hex strings, in the order
/// supplied. Used to merge per-script (core + per-CTM + gov-upgrade) TOMLs
/// into one merged `<env-out>/ecosystem.toml`.
pub fn merge_call_array_hex(chunks: &[&str]) -> anyhow::Result<String> {
    let mut merged: Vec<GovernanceCall> = Vec::new();
    for chunk in chunks {
        merged.extend(decode_calls(chunk)?);
    }
    Ok(format!("0x{}", hex::encode(encode_calls(&merged))))
}

/// Empty `Call[]` encoded as `0x…`.
pub fn empty_calls_hex() -> String {
    format!("0x{}", hex::encode(encode_calls(&[])))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize)]
    struct Package {
        governance_calls: GovernanceCallsTable,
    }

    #[test]
    fn the_bundle_is_read_from_its_one_key() {
        let package: Package =
            toml::from_str("[governance_calls]\ncalls = \"0x\"\n").expect("one bundle");
        assert!(decode_calls(&package.governance_calls.calls)
            .unwrap()
            .is_empty());
    }

    /// A package with per-stage keys is refused rather than read with those calls dropped.
    #[test]
    fn a_package_with_stage_keys_is_refused() {
        let err = toml::from_str::<Package>(
            "[governance_calls]\ncalls = \"0x\"\nstage1_calls = \"0x\"\n",
        )
        .unwrap_err();
        assert!(err.to_string().contains("stage1_calls"), "{err}");
    }
}
