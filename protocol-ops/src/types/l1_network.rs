use std::str::FromStr;

use alloy::primitives::{Address, B256};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::EnumIter;

use crate::common::addresses::{
    LOCAL_ZK_TOKEN_ADDRESS, LOCAL_ZK_TOKEN_ASSET_ID, MAINNET_WETH_ADDRESS, SEPOLIA_WETH_ADDRESS,
};

#[derive(
    Copy,
    Clone,
    Debug,
    Default,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Serialize,
    Deserialize,
    ValueEnum,
    EnumIter,
    strum::Display,
)]
pub enum L1Network {
    #[default]
    Localhost,
    Sepolia,
    Holesky,
    Mainnet,
}

impl L1Network {
    pub fn from_l1_rpc(rpc_url: &str) -> anyhow::Result<Self> {
        let chain_id = crate::common::ethereum::query_chain_id_sync(rpc_url)?;
        match chain_id {
            1 => Ok(Self::Mainnet),
            9 | 31337 => Ok(Self::Localhost),
            17000 => Ok(Self::Holesky),
            11155111 => Ok(Self::Sepolia),
            other => anyhow::bail!("Unrecognized L1 chain ID: {}", other),
        }
    }

    /// Canonical WETH for this L1. Unlike the ZK token below, WETH has a
    /// single well-known deployment per network, so it is resolved here
    /// rather than carried per env. It is baked as an immutable into
    /// `L1AssetRouter` and `L1NativeTokenVault`, so a wrong value can only be
    /// corrected by an implementation upgrade. There is deliberately no
    /// cross-network fallback: a network without a canonical address must
    /// pass `--token-weth-address` rather than silently inherit another
    /// network's WETH.
    pub fn weth_address(&self) -> anyhow::Result<Address> {
        let raw = match self {
            L1Network::Mainnet => MAINNET_WETH_ADDRESS,
            L1Network::Sepolia => SEPOLIA_WETH_ADDRESS,
            L1Network::Holesky | L1Network::Localhost => {
                anyhow::bail!("no canonical WETH address for {self}; pass --token-weth-address")
            }
        };
        Ok(Address::from_str(raw).expect("hardcoded WETH address must parse"))
    }

    /// `zk_token_asset_id` for live networks is intentionally read from
    /// `permanent-values/<env>.toml` rather than hard-coded here. There is no
    /// single "canonical" Sepolia or Mainnet ZK asset ID — the same L1
    /// network hosts multiple deployments (stage uses a different ZkTokenV2
    /// instance than testnet, mainnet has its own), and inlining a constant
    /// in this enum forces a code change every time a new env appears. The
    /// per-env TOML keeps the asset ID next to the other env-specific
    /// addresses (bridgehub, CTMs, etc.) and makes it discoverable by anyone
    /// onboarding a new chain. Only `Localhost` returns a built-in constant
    /// because interop tests deterministically deploy the token themselves.
    pub fn zk_token_asset_id(&self) -> anyhow::Result<B256> {
        match self {
            L1Network::Localhost => {
                // When testing locally, we deploy the ZK token inside interop tests, so we need to derive its asset id
                // from LOCAL_ZK_TOKEN_ADDRESS.
                let _ = LOCAL_ZK_TOKEN_ADDRESS;
                Ok(B256::from_str(LOCAL_ZK_TOKEN_ASSET_ID).unwrap())
            }
            L1Network::Sepolia | L1Network::Holesky | L1Network::Mainnet => anyhow::bail!(
                "no canonical ZK token asset ID for {self}; pass --zk-token-asset-id or use --env with zk_token_asset_id in permanent-values"
            ),
        }
    }
}
