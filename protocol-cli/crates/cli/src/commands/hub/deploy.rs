use std::path::{Path, PathBuf};

use clap::Parser;
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use protocol_cli_common::{
    forge::{Forge, ForgeArgs, ForgeRunner, ForgeScriptArgs},
    logger,
};
use protocol_cli_config::{
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
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::utils::{paths, runlog};

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubDeployArgs {
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    #[clap(long, help = "Owner address for the deployed contracts (default: sender)")]
    pub owner: Option<Address>,
    #[clap(long, help = "Enable support for legacy bridge testing", default_value_t = false)]
    pub with_legacy_bridge: bool,
    
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

pub async fn run(args: HubDeployArgs, shell: &Shell) -> anyhow::Result<()> {
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
    
    let owner = args.owner.unwrap_or(sender);
    
    let mut contracts: CoreContractsConfig = get_or_create_config(
        shell,
        args.contracts_path.clone(),
        CoreContractsConfig::default,
    )?;

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    let initial_deployment_config = InitialDeploymentConfig::default();

    logger::info("Deploying hub contracts...");
    deploy_contracts(
        shell,
        foundry_scripts_path,
        &mut contracts,
        &mut runner,
        &args.forge_args.script,
        args.l1_rpc_url.clone(),
        args.private_key.unwrap(),
        owner,
        &initial_deployment_config,
        args.with_legacy_bridge,
        true,
    )
    .await?;
    contracts.save(shell, args.contracts_path.clone())?;

    logger::outro("Hub contracts deployed");

    println!("");
    println!("{}", format!("Bridgehub Proxy Address: {:#x}", contracts.bridgehub_proxy_addr()));
    if let Ok(dir) = runlog::persist_runner_session(&runner, "hub.deploy") {
        println!("{}", format!("Runs saved to: {}", dir.display()));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn deploy_contracts(
    shell: &Shell,
    foundry_scripts_path: &Path,
    contracts: &mut CoreContractsConfig,
    runner: &mut ForgeRunner,
    forge_args: &ForgeScriptArgs,
    l1_rpc_url: String,
    private_key: H256,
    owner: Address,
    initial_deployment_config: &InitialDeploymentConfig,
    support_l2_legacy_shared_bridge_test: bool,
    broadcast: bool,
) -> anyhow::Result<()> {
    let deploy_config_path: PathBuf =
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.input(&foundry_scripts_path);

    let deploy_config = DeployL1Config::new(
        owner,
        initial_deployment_config,
        DEFAULT_ERA_CHAIN_ID,
        support_l2_legacy_shared_bridge_test,
    );
    deploy_config.save(shell, deploy_config_path)?;

    let mut forge = Forge::new(&foundry_scripts_path)
        .script(
            &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.script(),
            forge_args.clone(),
        )
        .with_ffi()
        .with_rpc_url(l1_rpc_url.to_string())
        .with_private_key(private_key)
        .with_slow();

    if broadcast {
        forge = forge.with_broadcast();
    }
    runner.run(shell, forge)?;

    let script_output = DeployL1CoreContractsOutput::read(
        shell,
        DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS.output(&foundry_scripts_path),
    )?;
    contracts.update_from_l1_output(&script_output);
    Ok(())
}
