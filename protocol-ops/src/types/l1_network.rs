use std::{collections::HashMap, str::FromStr};

use clap::ValueEnum;
use ethers::types::{Address, H256};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use strum::EnumIter;

// Embed DA config at compile time from contracts/configs/da.yaml.
const DA_CONFIG_YAML: &str = include_str!("../../../configs/da.yaml");

#[derive(Deserialize)]
struct DaConfig {
    avail: Option<HashMap<String, String>>,
}

lazy_static! {
    static ref DA_CONFIG: DaConfig =
        serde_yaml::from_str(DA_CONFIG_YAML).expect("Failed to parse embedded da.yaml");
}

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
    #[must_use]
    pub fn chain_id(&self) -> u64 {
        match self {
            L1Network::Localhost => 9,
            L1Network::Sepolia => 11_155_111,
            L1Network::Holesky => 17000,
            L1Network::Mainnet => 1,
        }
    }

    /// Look up the Avail L1 DA validator address for this network from configs/da.yaml.
    pub fn avail_l1_da_validator_addr(&self) -> Option<Address> {
        let key = match self {
            L1Network::Localhost => return None,
            L1Network::Sepolia => "sepolia",
            L1Network::Holesky => "holesky",
            L1Network::Mainnet => "mainnet",
        };
        DA_CONFIG
            .avail
            .as_ref()
            .and_then(|m| m.get(key))
            .map(|s| Address::from_str(s).expect("invalid address in da.yaml"))
    }

    pub fn zk_token_asset_id(&self) -> H256 {
        match self {
            L1Network::Localhost => {
                // When testing locally, we deploy the ZK token inside interop tests, so we need to derive its asset id
                // The address where ZK will be deployed at is 0x8207187d1682B3ebaF2e1bdE471aC9d5B886fD93
                H256::from_str("0x50c8daa176d24869d010ad74c2d374427601375ca2264e94f73784e299d572d4")
                    .unwrap()
            }
            L1Network::Sepolia => {
                // https://sepolia.etherscan.io/address/0x2569600E58850a0AaD61F7Dd2569516C3d909521#readProxyContract#F3
                H256::from_str("0x0d643837c76916220dfe0d5e971cfc3dc2c7569b3ce12851c8e8f17646d86bca")
                    .unwrap()
            }
            L1Network::Mainnet => {
                // https://etherscan.io/address/0x66A5cFB2e9c529f14FE6364Ad1075dF3a649C0A5#readProxyContract#F3
                H256::from_str("0x83e2fbc0a739b3c765de4c2b4bf8072a71ea8fbb09c8cf579c71425d8bc8804a")
                    .unwrap()
            }
            L1Network::Holesky => H256::zero(),
        }
    }
}
