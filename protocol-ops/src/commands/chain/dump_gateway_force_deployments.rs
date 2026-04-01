use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger, paths,
};

/// Write `force_deployments_data` TOML for gateway vote preparation (read-only forge script).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DumpGatewayForceDeploymentsArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// CTM proxy address (`run(address)`).
    #[clap(long, help_heading = "Input")]
    pub ctm_proxy: Address,

    /// Output path relative to `l1-contracts` (e.g. `/script-out/force_dep.toml`). Sets
    /// `FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH` for the forge script.
    #[clap(long, help_heading = "Output")]
    pub dump_toml_rel: String,
}

pub async fn run(args: DumpGatewayForceDeploymentsArgs) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::path_to_foundry_scripts();
    std::fs::create_dir_all(contracts_path.join("script-out"))
        .context("create l1-contracts/script-out")?;

    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "run(address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args
        .additional_args
        .push(format!("{:#x}", args.ctm_proxy));

    let script = Forge::new(&contracts_path)
        .script(
            Path::new(
                "deploy-scripts/dev/DumpForceDeploymentsForGateway.s.sol:DumpForceDeploymentsForGateway",
            ),
            script_args,
        )
        .with_env(
            "FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH",
            args.dump_toml_rel.clone(),
        );

    logger::step("Dumping force deployments data for gateway vote-prep");
    logger::info(format!("CTM proxy: {:#x}", args.ctm_proxy));
    logger::info(format!("Dump TOML (rel): {}", args.dump_toml_rel));

    runner
        .run(script)
        .context("forge DumpForceDeploymentsForGateway")?;

    write_output_if_requested(
        "chain.dump-gateway-force-deployments",
        args.shared.out_path.as_deref(),
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "ctm_proxy": format!("{:#x}", args.ctm_proxy),
            "dump_toml_rel": &args.dump_toml_rel,
        }),
    )?;

    logger::success("Force deployments dump completed");
    Ok(())
}
