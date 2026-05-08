use std::str::FromStr;

use clap::ValueEnum;
use ethers::types::H256;
use serde::{Deserialize, Serialize};
use strum::EnumIter;

use crate::common::addresses::{LOCAL_ZK_TOKEN_ADDRESS, LOCAL_ZK_TOKEN_ASSET_ID};

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

    pub fn zk_token_asset_id(&self) -> anyhow::Result<H256> {
        match self {
            L1Network::Localhost => {
                // When testing locally, we deploy the ZK token inside interop tests, so we need to derive its asset id
                // from LOCAL_ZK_TOKEN_ADDRESS.
                let _ = LOCAL_ZK_TOKEN_ADDRESS;
                Ok(H256::from_str(LOCAL_ZK_TOKEN_ASSET_ID).unwrap())
            }
            L1Network::Sepolia | L1Network::Holesky | L1Network::Mainnet => anyhow::bail!(
                "no canonical ZK token asset ID for {self}; pass --zk-token-asset-id or use --env with zk_token_asset_id in permanent-values"
            ),
        }
    }
}
