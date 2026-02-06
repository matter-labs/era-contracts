use std::path::{Path, PathBuf};

use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_ops_common::{
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
    logger,
};
use protocol_ops_config::{
    DEFAULT_ERA_CHAIN_ID,
    forge_interface::{
        deploy_ecosystem::{
            input::{DeployL1Config, InitialDeploymentConfig},
            output::DeployL1CoreContractsOutput,
        },
        script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
    },
    traits::{get_or_create_config, ReadConfig, SaveConfig},
    CoreContractsConfig,
};
use protocol_ops_types::{DAValidatorType, L1Network, L2ChainId, L2DACommitmentScheme, VMOption};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::utils::{paths, runlog};

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubRegisterChainArgs {
    #[clap(long, help = "Chain owner address")]
    pub owner: Option<String>,
    #[clap(
        long,
        help = "Commit operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub commit_operator: Option<String>,
    #[clap(
        long,
        help = "Prove operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub prove_operator: Option<String>,
    #[clap(
        long,
        help = "Execute operator address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub execute_operator: Option<String>,
    #[clap(
        long,
        help = "Token multiplier setter address",
        default_value = "0x0000000000000000000000000000000000000000"
    )]
    pub token_multiplier_setter: Option<String>,
    #[clap(long, help = "Chain ID", default_value_t = 271)]
    pub chain_id: i64,
    #[clap(
        long,
        help = "Base token address",
        default_value = "0x0000000000000000000000000000000000000001"
    )]
    pub base_token_addr: String,
    #[clap(long, help = "Base token multiplier numerator", default_value_t = 1)]
    pub base_token_gas_price_multiplier_numerator: u64,
    #[clap(long, help = "Base token multiplier denominator", default_value_t = 1)]
    pub base_token_gas_price_multiplier_denominator: u64,
    #[clap(long, value_enum, help = "Data availability mode", default_value_t = DAValidatorType::Rollup)]
    pub da_mode: DAValidatorType,

    #[clap(long, help = "Enable support for legacy bridge testing", default_value_t = false)]
    pub with_legacy_bridge: bool,
    
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, help = "Sender address")]
    pub sender: Option<Address>,
    #[clap(long, help = "Private key for the sender")]
    pub private_key: Option<H256>,

    #[clap(long)]
    pub contracts_path: PathBuf,

    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,
}

pub async fn run(args: HubRegisterChainArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path_buf = paths::path_from_root("l1-contracts");
    let foundry_scripts_path = foundry_scripts_path_buf.as_path();

    // Parse sender and private_key
    if args.private_key.is_none() && args.sender.is_none() {
        anyhow::bail!("Either private key or sender address must be provided");
    }
    let sender = if args.private_key.is_some() {
        let pk = args.private_key.unwrap();
        let wallet = LocalWallet::from_bytes(pk.as_bytes()).unwrap();
        if args.sender.is_some() && args.sender.unwrap() != wallet.address() {
            anyhow::bail!("Sender address does not match private key: got {:#x}, want {:#x}", args.sender.unwrap(), wallet.address());
        }
        wallet.address()
    } else {
        args.sender.unwrap()
    }; 

    logger::info("Registering chain...");
    Ok(())
}
