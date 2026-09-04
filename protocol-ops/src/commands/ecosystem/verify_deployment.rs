//! `ecosystem verify-deployment` — verify a live ecosystem against a local
//! contracts build.
//!
//! Read-only: it makes `eth_call`, `eth_getCode`, `eth_getStorageAt` and
//! `eth_getLogs` requests and nothing else, so it is safe to point at
//! mainnet.

use alloy::primitives::Address;
use anyhow::Context;
use clap::Parser;
use std::path::PathBuf;

use crate::common::env_config::EnvConfig;
use crate::deployment_verification::{self, VerifyDeploymentInput};

/// `MAX_NUMBER_OF_ZK_CHAINS` in `l1-contracts/contracts/common/Config.sol`.
const DEFAULT_MAX_NUMBER_OF_ZK_CHAINS: u64 = 100;

#[derive(Debug, Parser)]
pub struct VerifyDeploymentArgs {
    /// Bridgehub proxy address. Everything else is discovered from it.
    #[clap(long, help_heading = "Input")]
    pub bridgehub: Option<Address>,

    /// Per-env preset (`stage` / `testnet` / `mainnet` / `local`), used for
    /// `--bridgehub` and `--era-chain-id` when those are omitted.
    #[clap(long, help_heading = "Input")]
    pub env: Option<String>,

    #[clap(long, default_value = "http://localhost:8545", help_heading = "Input")]
    pub l1_rpc_url: String,

    /// Lower bound for the log scans (chain creation params, pending admins,
    /// DA pairs). Use the ecosystem's first deployment block; the default
    /// scans from genesis, which many hosted RPCs reject.
    #[clap(long, default_value_t = 0, help_heading = "Input")]
    pub from_block: u64,

    /// Expected Era chain id baked into the force deployments.
    #[clap(long, help_heading = "Expectations")]
    pub era_chain_id: Option<u64>,

    /// Expected `L1_WETH_TOKEN` immutable. Getting this wrong is only
    /// fixable by an implementation upgrade, so it is worth pinning.
    #[clap(long, help_heading = "Expectations")]
    pub weth: Option<Address>,

    /// Expected `maxNumberOfZKChains` in the force deployments.
    #[clap(long, default_value_t = DEFAULT_MAX_NUMBER_OF_ZK_CHAINS, help_heading = "Expectations")]
    pub max_number_of_zk_chains: u64,

    /// Whether the testnet (mock-proof) verifier is expected. Omit to have
    /// the tool report which one is deployed without failing either way.
    #[clap(long, help_heading = "Expectations")]
    pub expect_testnet_verifier: Option<bool>,

    /// L1 address of the ZK token this ecosystem's `zkTokenAssetId` should
    /// denote. The asset id is `keccak(abi.encode(l1ChainId, L2_NTV, token))`;
    /// without this flag it can only be reported, not checked.
    #[clap(long, help_heading = "Expectations")]
    pub zk_token_l1_address: Option<Address>,

    /// Compute units per second to pace the RPC client with. Hosted
    /// endpoints throttle a full run otherwise; lower it if you still see 429s.
    #[clap(long, default_value_t = 200, help_heading = "Input")]
    pub compute_units_per_second: u64,

    /// Genesis config to compare the deployed genesis root and prover VK
    /// against (default: `configs/genesis/zksync-os/latest.json`).
    #[clap(long, help_heading = "Expectations")]
    pub genesis_config: Option<PathBuf>,
}

pub async fn run(args: VerifyDeploymentArgs) -> anyhow::Result<()> {
    let env_config = args.env.as_deref().map(EnvConfig::load).transpose()?;

    let bridgehub = args
        .bridgehub
        .or_else(|| env_config.as_ref().map(|config| config.bridgehub()))
        .context("--bridgehub or --env must be supplied")?;
    let era_chain_id = args
        .era_chain_id
        .or_else(|| env_config.as_ref().and_then(|config| config.era_chain_id()));

    deployment_verification::run(VerifyDeploymentInput {
        bridgehub,
        l1_rpc_url: args.l1_rpc_url,
        from_block: args.from_block,
        expected_era_chain_id: era_chain_id,
        expected_weth: args.weth,
        expected_max_number_of_zk_chains: args.max_number_of_zk_chains,
        expect_testnet_verifier: args.expect_testnet_verifier,
        zk_token_l1_address: args.zk_token_l1_address,
        genesis_config: args.genesis_config,
        compute_units_per_second: args.compute_units_per_second,
    })
    .await
}
