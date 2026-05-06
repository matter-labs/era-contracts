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

use anyhow::Context;
use ethers::abi::{decode as abi_decode, encode as abi_encode, ParamType, Token};
use ethers::types::{Address, U256};
use ethers::utils::hex;

#[derive(Clone, Debug)]
pub struct GovernanceCall {
    pub target: Address,
    pub value: U256,
    pub data: Vec<u8>,
}

/// `abi.encode(Call[])`.
pub fn encode_calls(calls: &[GovernanceCall]) -> Vec<u8> {
    let tokens: Vec<Token> = calls
        .iter()
        .map(|c| {
            Token::Tuple(vec![
                Token::Address(c.target),
                Token::Uint(c.value),
                Token::Bytes(c.data.clone()),
            ])
        })
        .collect();
    abi_encode(&[Token::Array(tokens)])
}

/// `abi.decode(Call[])` from a `0x`-prefixed hex string.
pub fn decode_calls(hex_str: &str) -> anyhow::Result<Vec<GovernanceCall>> {
    let trimmed = hex_str.trim_start_matches("0x");
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let raw = hex::decode(trimmed).context("invalid governance calls hex")?;
    let array_ty = ParamType::Array(Box::new(ParamType::Tuple(vec![
        ParamType::Address,
        ParamType::Uint(256),
        ParamType::Bytes,
    ])));
    let mut tokens = abi_decode(&[array_ty], &raw).context("Call[] ABI decode")?;
    let arr = match tokens.pop() {
        Some(Token::Array(a)) => a,
        _ => anyhow::bail!("expected Call[]"),
    };
    let mut out = Vec::with_capacity(arr.len());
    for tok in arr {
        let parts = match tok {
            Token::Tuple(parts) if parts.len() == 3 => parts,
            _ => anyhow::bail!("Call must be a 3-element tuple"),
        };
        let target = parts[0].clone().into_address().context("Call.target")?;
        let value = parts[1].clone().into_uint().context("Call.value")?;
        let data = parts[2].clone().into_bytes().context("Call.data")?;
        out.push(GovernanceCall {
            target,
            value,
            data,
        });
    }
    Ok(out)
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
