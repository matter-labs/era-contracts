use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};


use crate::commands::output::write_output_if_requested;
use crate::common::forge::{Forge, ForgeRunner, ForgeScriptArg};
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainUpgradeArgs {
    /// Chain diamond proxy address
    #[clap(long)]
    pub chain_address: Address,
    /// Chain admin address
    #[clap(long)]
    pub admin_address: Address,
    /// AccessControlRestriction contract address
    #[clap(long)]
    pub access_control_restriction: Address,
    /// Skip broadcasting transactions
    #[clap(long, default_value_t = false)]
    pub skip_broadcast: bool,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

#[derive(Serialize)]
struct ChainUpgradeOutputPayload {
    chain_address: Address,
    admin_address: Address,
    access_control_restriction: Address,
    skip_broadcast: bool,
}

pub async fn run(args: ChainUpgradeArgs) -> anyhow::Result<()> {
    let private_key = args
        .shared
        .private_key
        .ok_or_else(|| anyhow::anyhow!("--private-key is required"))?;

    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;
    let script_path = Path::new("deploy-scripts/AdminFunctions.s.sol");
    let script_full_path = runner.foundry_scripts_path.join(script_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "upgradeChainFromCTM(address,address,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT,
    });
    script_args.add_arg(ForgeScriptArg::PrivateKey {
        private_key: format!("{:#x}", private_key),
    });
    if !args.skip_broadcast {
        script_args.add_arg(ForgeScriptArg::Broadcast);
    }
    script_args.additional_args.extend([
        format!("{:#x}", args.chain_address),
        format!("{:#x}", args.admin_address),
        format!("{:#x}", args.access_control_restriction),
    ]);

    let forge = Forge::new(&runner.foundry_scripts_path).script(script_path, script_args);

    logger::step("Running chain upgrade via AdminFunctions.s.sol");
    logger::info(format!("Chain address: {:#x}", args.chain_address));
    logger::info(format!("Admin address: {:#x}", args.admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));
    logger::info(format!("Broadcast: {}", !args.skip_broadcast));

    runner
        .run(forge)
        .context("Failed to execute forge script for chain upgrade")?;

    let empty_input = serde_json::json!({});
    let out_payload = ChainUpgradeOutputPayload {
        chain_address: args.chain_address,
        admin_address: args.admin_address,
        access_control_restriction: args.access_control_restriction,
        skip_broadcast: args.skip_broadcast,
    };
    write_output_if_requested("chain.upgrade", &args.shared, &runner, &empty_input, &out_payload)
        .await?;

    logger::success("Chain upgrade completed");
    Ok(())
}
