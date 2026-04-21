use std::path::PathBuf;

use clap::Args;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::common::forge::ForgeScriptArgs;

/// Sender / RPC / simulate / `--out` / forge flags shared by most protocol_ops commands.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct SharedRunArgs {
    /// Sender address
    #[clap(long, help_heading = "Signers")]
    pub sender: Option<Address>,
    /// Sender private key
    #[clap(long, visible_alias = "pk", help_heading = "Auth")]
    pub private_key: Option<H256>,

    /// L1 RPC URL
    #[clap(
        long,
        default_value = "http://localhost:8545",
        help_heading = "Execution"
    )]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,

    /// Write full JSON output to file
    #[clap(long = "out", help_heading = "Output")]
    pub out_path: Option<PathBuf>,

    /// Write transactions in Gnosis Safe Transaction Builder JSON format
    #[clap(long, help_heading = "Output")]
    pub safe_transactions_out: Option<PathBuf>,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}
