use std::path::PathBuf;

use clap::Parser;
use ethers::types::{Address, H256};
use protocol_cli_common::{
    forge::{ForgeArgs, ForgeRunner},
    logger,
};
use protocol_cli_config::forge_interface::{
    deploy_ecosystem::{
        input::{DeployL1Config, InitialDeploymentConfig},
        output::DeployL1CoreContractsOutput,
    },
    script_params::DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use xshell::Shell;

use crate::forge_ctx::{resolve_sender, ForgeContext};
use crate::utils::paths;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubDeployArgs {
    #[clap(long, help = "Owner address for the deployed contracts (default: sender)")]
    pub owner: Option<Address>,

    // Common flags
    #[clap(long, help = "L1 RPC URL", default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,
    #[clap(long, help = "Private key for the sender")]
    pub private_key: Option<H256>,
    #[clap(long, help = "Sender address (unlocked account mode if no private key)")]
    pub sender: Option<Address>,
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeArgs,

    // Dev options
    #[clap(long, help = "Use dev defaults", default_value_t = false, help_heading = "Dev options")]
    pub dev: bool,
    #[clap(long, help = "Enable support for legacy bridge testing", default_value_t = false, help_heading = "Dev options")]
    pub with_legacy_bridge: bool,
    #[clap(long, help = "Era chain ID", default_value_t = 270, help_heading = "Dev options")]
    pub era_chain_id: u64,
}

pub async fn run(args: HubDeployArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");
    let (auth, sender) = resolve_sender(args.private_key, args.sender, args.dev)?;
    let owner = args.owner.unwrap_or(sender);

    let mut runner = ForgeRunner::new(args.forge_args.runner.clone());
    let mut ctx = ForgeContext {
        shell,
        foundry_scripts_path: foundry_scripts_path.as_path(),
        runner: &mut runner,
        forge_args: &args.forge_args.script,
        l1_rpc_url: &args.l1_rpc_url,
        auth: &auth,
    };

    let deploy_config = DeployL1Config::new(
        owner,
        &InitialDeploymentConfig::default(),
        args.era_chain_id,
        args.with_legacy_bridge,
    );

    logger::info("Deploying hub contracts...");
    let output: DeployL1CoreContractsOutput = ctx.run(
        &DEPLOY_ECOSYSTEM_CORE_CONTRACTS_SCRIPT_PARAMS,
        &deploy_config,
    )?;

    let plan = build_plan(&output, ctx.runner);
    let plan_json = serde_json::to_string_pretty(&plan)?;
    if let Some(out_path) = &args.forge_args.runner.out {
        std::fs::write(out_path, &plan_json)?;
        logger::info(format!("Plan written to: {}", out_path.display()));
    } else {
        println!("{}", plan_json);
    }

    logger::outro("Hub contracts deployed");
    Ok(())
}

fn build_plan(output: &DeployL1CoreContractsOutput, runner: &ForgeRunner) -> serde_json::Value {
    let deployed = &output.deployed_addresses;

    let mut transactions = Vec::new();
    for run in runner.runs() {
        if let Some(txs) = run.transactions() {
            for tx in txs {
                transactions.push(tx.clone());
            }
        }
    }

    json!({
        "command": "hub.deploy",
        "transactions": transactions,
        "artifacts": {
            "create2_factory_addr": format!("{:#x}", output.contracts.create2_factory_addr),
            "create2_factory_salt": format!("{:#x}", output.contracts.create2_factory_salt),
            "core_ecosystem_contracts": {
                "bridgehub_proxy_addr": format!("{:#x}", deployed.bridgehub.bridgehub_proxy_addr),
                "message_root_proxy_addr": format!("{:#x}", deployed.bridgehub.message_root_proxy_addr),
                "transparent_proxy_admin_addr": format!("{:#x}", deployed.transparent_proxy_admin_addr),
                "stm_deployment_tracker_proxy_addr": format!("{:#x}", deployed.bridgehub.ctm_deployment_tracker_proxy_addr),
                "native_token_vault_addr": format!("{:#x}", deployed.native_token_vault_addr),
                "chain_asset_handler_proxy_addr": format!("{:#x}", deployed.bridgehub.chain_asset_handler_proxy_addr),
            },
            "bridges": {
                "erc20": {
                    "l1_address": format!("{:#x}", deployed.bridges.erc20_bridge_proxy_addr),
                },
                "shared": {
                    "l1_address": format!("{:#x}", deployed.bridges.shared_bridge_proxy_addr),
                },
                "l1_nullifier_addr": format!("{:#x}", deployed.bridges.l1_nullifier_proxy_addr),
            },
            "l1": {
                "governance_addr": format!("{:#x}", deployed.governance_addr),
                "chain_admin_addr": format!("{:#x}", deployed.chain_admin),
                "access_control_restriction_addr": format!("{:#x}", deployed.access_control_restriction_addr),
            },
        },
    })
}
