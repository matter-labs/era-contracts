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
    wallets::Wallet,
};

/// Deploy `GatewayTransactionFilterer` and configure it on bridgehub (`run(address,uint256)`).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DeployGatewayTransactionFiltererArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Bridgehub proxy address.
    #[clap(long, help_heading = "Input")]
    pub bridgehub_proxy_address: Address,

    /// Chain ID to pass to `run(address,uint256)`.
    #[clap(long, help_heading = "Input")]
    pub chain_id: u64,
}

pub async fn run(args: DeployGatewayTransactionFiltererArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.shared.private_key, args.shared.sender)
        .context("need --private-key or --sender for broadcast")?;

    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::path_to_foundry_scripts();

    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "run(address,uint256)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend([
        format!("{:#x}", args.bridgehub_proxy_address),
        args.chain_id.to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(
            Path::new(
                "deploy-scripts/dev/DeployAndSetGatewayTransactionFilterer.s.sol:DeployAndSetGatewayTransactionFilterer",
            ),
            script_args,
        )
        .with_wallet(&sender, runner.simulate);

    logger::step("Deploying gateway transaction filterer");
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub_proxy_address));
    logger::info(format!("Chain ID: {}", args.chain_id));

    runner
        .run(script)
        .context("forge DeployAndSetGatewayTransactionFilterer")?;

    write_output_if_requested(
        "chain.deploy-gateway-transaction-filterer",
        args.shared.out_path.as_deref(),
        args.shared.safe_transactions_out.as_deref(),
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "bridgehub_proxy_address": format!("{:#x}", args.bridgehub_proxy_address),
            "chain_id": args.chain_id,
        }),
    )?;

    logger::success("Gateway transaction filterer deployed");
    Ok(())
}
