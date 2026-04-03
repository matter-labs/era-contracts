use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};

use crate::commands::output::write_output_if_requested;
use crate::common::paths;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger,
    wallets::Wallet,
};

/// Stages for migrating an existing chain to a gateway.
#[derive(Debug, Clone, Copy, clap::ValueEnum, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MigrateToGatewayStage {
    /// Step 1: Pause deposits on the chain before migration.
    PauseDeposits,
    /// Step 2: Submit the migration transaction (L1 → gateway L2).
    Migrate,
    /// Step 3: Notify the server about the migration.
    NotifyServer,
}

impl std::fmt::Display for MigrateToGatewayStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PauseDeposits => write!(f, "pause-deposits"),
            Self::Migrate => write!(f, "migrate"),
            Self::NotifyServer => write!(f, "notify-server"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct MigrateToGatewayArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Migration stage to execute.
    #[clap(long, value_enum)]
    pub stage: MigrateToGatewayStage,

    /// Bridgehub proxy address.
    #[clap(long)]
    pub bridgehub_proxy_address: Address,

    /// Chain ID of the chain being migrated.
    #[clap(long)]
    pub chain_id: u64,

    /// Gateway chain ID (the settlement layer to migrate to).
    /// Required for the migrate stage.
    #[clap(long)]
    pub gateway_chain_id: Option<u64>,

    /// L1 gas price in wei (required for the migrate stage).
    #[clap(long)]
    pub l1_gas_price: Option<u64>,

    /// Path to the gateway vote preparation output TOML (for reading diamond_cut_data).
    /// Required for the migrate stage.
    #[clap(long, default_value = "/script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_output_path: String,

    /// Refund recipient address for L1→L2 transactions (required for migrate stage).
    #[clap(long)]
    pub refund_recipient: Option<Address>,
}

pub async fn run(args: MigrateToGatewayArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    match args.stage {
        MigrateToGatewayStage::PauseDeposits => run_pause_deposits(&mut runner, &sender, &args),
        MigrateToGatewayStage::Migrate => run_migrate(&mut runner, &sender, &args),
        MigrateToGatewayStage::NotifyServer => run_notify_server(&mut runner, &sender, &args),
    }
}

fn resolve_l1_contracts_path() -> anyhow::Result<PathBuf> {
    paths::resolve_l1_contracts_path()
}

fn build_admin_functions_script(
    contracts_path: &Path,
    runner: &ForgeRunner,
    args: &MigrateToGatewayArgs,
    sig: &str,
    additional_args: Vec<String>,
) -> anyhow::Result<crate::common::forge::ForgeScript> {
    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: sig.to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend(additional_args);

    Ok(Forge::new(contracts_path).script(Path::new(script_path), script_args))
}

// ─── Step 1: Pause deposits ─────────────────────────────────────────────────

fn run_pause_deposits(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &MigrateToGatewayArgs,
) -> anyhow::Result<()> {
    let contracts_path = resolve_l1_contracts_path()?;

    let script = build_admin_functions_script(
        &contracts_path,
        runner,
        args,
        "pauseDepositsBeforeInitiatingMigration(address,uint256,bool)",
        vec![
            format!("{:#x}", args.bridgehub_proxy_address),
            args.chain_id.to_string(),
            "true".to_string(),
        ],
    )?
    .with_wallet(sender, runner.simulate);

    logger::step("Pausing deposits before migration");
    logger::info(format!("Chain ID: {}", args.chain_id));

    runner.run(script).context("Failed to pause deposits")?;

    write_stage_output(runner, args, "pause-deposits")?;
    logger::success("Deposits paused");
    Ok(())
}

// ─── Step 2: Migrate ─────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct VotePreparationOutput {
    pub diamond_cut_data: String,
}

fn run_migrate(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &MigrateToGatewayArgs,
) -> anyhow::Result<()> {
    let gateway_chain_id = args
        .gateway_chain_id
        .ok_or_else(|| anyhow::anyhow!("--gateway-chain-id is required for migrate stage"))?;
    let l1_gas_price = args
        .l1_gas_price
        .ok_or_else(|| anyhow::anyhow!("--l1-gas-price is required for migrate stage"))?;
    let refund_recipient = args
        .refund_recipient
        .ok_or_else(|| anyhow::anyhow!("--refund-recipient is required for migrate stage"))?;

    let contracts_path = resolve_l1_contracts_path()?;

    // Read diamond_cut_data from the gateway vote preparation output
    let output_path =
        contracts_path.join(args.vote_preparation_output_path.trim_start_matches('/'));
    let toml_content = std::fs::read_to_string(&output_path).with_context(|| {
        format!(
            "Failed to read vote preparation output: {}. Run convert-to-gateway vote-prepare first.",
            output_path.display()
        )
    })?;
    let output: VotePreparationOutput =
        toml::from_str(&toml_content).context("Failed to parse vote preparation output")?;

    let diamond_cut_data_hex = format!("0x{}", output.diamond_cut_data.trim_start_matches("0x"));

    let script = build_admin_functions_script(
        &contracts_path,
        runner,
        args,
        "migrateChainToGateway(address,uint256,uint256,uint256,bytes,address,bool)",
        vec![
            format!("{:#x}", args.bridgehub_proxy_address),
            l1_gas_price.to_string(),
            args.chain_id.to_string(),
            gateway_chain_id.to_string(),
            diamond_cut_data_hex,
            format!("{:#x}", refund_recipient),
            "true".to_string(),
        ],
    )?
    .with_wallet(sender, runner.simulate);

    logger::step("Migrating chain to gateway");
    logger::info(format!("Chain ID: {}", args.chain_id));
    logger::info(format!("Gateway chain ID: {}", gateway_chain_id));
    logger::info(format!("L1 gas price: {}", l1_gas_price));

    runner
        .run(script)
        .context("Failed to migrate chain to gateway")?;

    write_stage_output(runner, args, "migrate")?;
    logger::success("Chain migration submitted");
    Ok(())
}

// ─── Step 3: Notify server ──────────────────────────────────────────────────

fn run_notify_server(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &MigrateToGatewayArgs,
) -> anyhow::Result<()> {
    let contracts_path = resolve_l1_contracts_path()?;

    let script = build_admin_functions_script(
        &contracts_path,
        runner,
        args,
        "notifyServerMigrationToGateway(address,uint256,bool)",
        vec![
            format!("{:#x}", args.bridgehub_proxy_address),
            args.chain_id.to_string(),
            "true".to_string(),
        ],
    )?
    .with_wallet(sender, runner.simulate);

    logger::step("Notifying server about migration");
    logger::info(format!("Chain ID: {}", args.chain_id));

    runner
        .run(script)
        .context("Failed to notify server about migration")?;

    write_stage_output(runner, args, "notify-server")?;
    logger::success("Server notified about migration");
    Ok(())
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn write_stage_output(
    runner: &ForgeRunner,
    args: &MigrateToGatewayArgs,
    stage: &str,
) -> anyhow::Result<()> {
    #[derive(Serialize)]
    struct StageOutput<'a> {
        stage: &'a str,
        chain_id: u64,
    }
    write_output_if_requested(
        "chain.migrate-to-gateway",
        args.shared.out_path.as_deref(),
        runner,
        &serde_json::json!({"stage": stage}),
        &StageOutput {
            stage,
            chain_id: args.chain_id,
        },
    )
}
