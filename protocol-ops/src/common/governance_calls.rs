//! ABI helpers for the `Call[]` payloads embedded in our governance TOMLs.
//!
//! Every prepare command writes a TOML of the form:
//!
//! ```toml
//! [governance_calls]
//! stage0_calls = "0x…"   # abi.encode(Call[])
//! stage1_calls = "0x…"
//! stage2_calls = "0x…"
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
/// into one merged `<out>/prepare/governance.toml`.
pub fn merge_call_array_hex(stages: &[&str]) -> anyhow::Result<String> {
    let mut merged: Vec<GovernanceCall> = Vec::new();
    for stage in stages {
        merged.extend(decode_calls(stage)?);
    }
    Ok(format!("0x{}", hex::encode(encode_calls(&merged))))
}

/// Empty `Call[]` encoded as `0x…`.
pub fn empty_calls_hex() -> String {
    format!("0x{}", hex::encode(encode_calls(&[])))
}
