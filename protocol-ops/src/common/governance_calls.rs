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

use std::collections::BTreeMap;

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

/// The CTM prepare's `[ctm_proxy_admin_split]` (`[ctms.<key>.ctm_proxy_admin_split]` once merged):
/// the calls that move the CTM domain off the ecosystem `ProxyAdmin` onto the CTM-domain one the
/// prepare binds. Governance executes them on their own, before the bundle; they are never part
/// of `[governance_calls]`.
#[derive(Clone, Debug, Deserialize)]
pub struct CtmProxyAdminSplit {
    pub ecosystem_proxy_admin: Address,
    pub ctm_proxy_admin: Address,
    pub governance: Address,
    /// `abi.encode(Call[])` as `0x…` hex: one `changeProxyAdmin(proxy, ctm_proxy_admin)` on the
    /// ecosystem `ProxyAdmin` per CTM-domain proxy still behind it, none once the domain is split.
    pub calls: String,
}

/// The `[ctms.<key>.ctm_proxy_admin_split]` tables of a merged package, by CTM key.
pub fn ctm_proxy_admin_splits(
    root: &toml::Value,
) -> anyhow::Result<BTreeMap<String, CtmProxyAdminSplit>> {
    let mut splits = BTreeMap::new();
    let ctms = root.get("ctms").and_then(toml::Value::as_table);
    for (key, ctm) in ctms.into_iter().flatten() {
        if let Some(split) = ctm.get("ctm_proxy_admin_split") {
            let split = split
                .clone()
                .try_into()
                .with_context(|| format!("[ctms.{key}.ctm_proxy_admin_split]"))?;
            splits.insert(key.clone(), split);
        }
    }
    Ok(splits)
}

/// Every call of a merged package's `[ctms.*.ctm_proxy_admin_split]` tables, in CTM-key order:
/// what governance executes before the bundle. Empty for a package without one.
pub fn ctm_proxy_admin_split_calls(root: &toml::Value) -> anyhow::Result<Vec<GovernanceCall>> {
    let mut calls = Vec::new();
    for (key, split) in ctm_proxy_admin_splits(root)? {
        calls.extend(decode_calls(&split.calls).with_context(|| {
            format!("[ctms.{key}.ctm_proxy_admin_split] calls does not decode as Call[]")
        })?);
    }
    Ok(calls)
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

    fn split_toml(calls: &str) -> String {
        format!(
            "[ctms.zksync_os.ctm_proxy_admin_split]\n\
             ecosystem_proxy_admin = \"{}\"\n\
             ctm_proxy_admin = \"{}\"\n\
             governance = \"{}\"\n\
             calls = \"{calls}\"\n",
            Address::repeat_byte(0xE0),
            Address::repeat_byte(0xC0),
            Address::repeat_byte(0x60),
        )
    }

    #[test]
    fn the_split_calls_are_read_from_each_ctm_section() {
        let call = GovernanceCall {
            target: Address::repeat_byte(0xE0),
            value: U256::ZERO,
            data: vec![0x7e, 0xff, 0x27, 0x5e],
        };
        let encoded = format!("0x{}", hex::encode(encode_calls(&[call])));
        let root: toml::Value = toml::from_str(&split_toml(&encoded)).unwrap();
        let splits = ctm_proxy_admin_splits(&root).unwrap();
        assert_eq!(
            splits["zksync_os"].ctm_proxy_admin,
            Address::repeat_byte(0xC0)
        );
        let calls = ctm_proxy_admin_split_calls(&root).unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].target, Address::repeat_byte(0xE0));
    }

    #[test]
    fn an_empty_or_absent_split_carries_no_calls() {
        let empty: toml::Value = toml::from_str(&split_toml(&empty_calls_hex())).unwrap();
        assert!(ctm_proxy_admin_split_calls(&empty).unwrap().is_empty());
        let absent: toml::Value = toml::from_str(
            "[ctms.zksync_os.state_transition]\n[governance_calls]\ncalls = \"0x\"\n",
        )
        .unwrap();
        assert!(ctm_proxy_admin_splits(&absent).unwrap().is_empty());
        assert!(ctm_proxy_admin_split_calls(&absent).unwrap().is_empty());
    }

    #[test]
    fn a_split_without_its_calls_is_refused() {
        let root: toml::Value = toml::from_str(
            "[ctms.zksync_os.ctm_proxy_admin_split]\nctm_proxy_admin = \"0x00000000000000000000000000000000000000c0\"\n",
        )
        .unwrap();
        let err = ctm_proxy_admin_splits(&root).unwrap_err();
        assert!(
            format!("{err:#}").contains("ctm_proxy_admin_split"),
            "{err:#}"
        );
    }
}
