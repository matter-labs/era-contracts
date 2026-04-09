use std::path::Path;

use anyhow::Context;
use clap::{Args, Parser, Subcommand};
use ethers::types::Address;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::commands::output::write_output_if_requested;
use crate::common::paths;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger,
    wallets::Wallet,
};

/// Shared arguments for all convert stages.
#[derive(Debug, Clone, Serialize, Deserialize, Args)]
pub struct ConvertShared {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Bridgehub proxy address.
    #[clap(long)]
    pub bridgehub: Address,

    /// Gateway chain ID (the chain being converted to a gateway).
    #[clap(long)]
    pub gateway_chain_id: u64,
}

/// Convert a chain into a gateway (settlement layer).
#[derive(Subcommand, Debug)]
#[command(after_long_help = "\
Steps (run in order):
  1. deploy-filterer       Deploy and set GatewayTransactionFilterer
  2. grant-whitelist       Whitelist deployer addresses on the gateway
  3. vote-prepare          Prepare governance vote (deploys CTM contracts)
  4. governance-execute    Execute governance calls from vote-prepare output
  5. revoke-whitelist      Revoke deployer whitelist after deployment")]
pub enum ConvertCommands {
    /// Step 1: Deploy GatewayTransactionFilterer and set it on the chain diamond
    DeployFilterer(DeployFiltererArgs),
    /// Step 2: Grant deployer whitelist on the gateway chain's transaction filterer
    GrantWhitelist(GrantWhitelistArgs),
    /// Step 3: Deploy gateway CTM contracts and prepare governance calls
    VotePrepare(VotePrepareArgs),
    /// Step 4: Execute governance calls from the vote preparation output
    GovernanceExecute(GovernanceExecuteArgs),
    /// Step 5: Revoke deployer whitelist after deployment is complete
    RevokeWhitelist(RevokeWhitelistArgs),
}

// ── DeployFilterer args ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct DeployFiltererArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Bridgehub proxy address.
    #[clap(long)]
    pub bridgehub: Address,

    /// Gateway chain ID (the chain that will host the transaction filterer).
    #[clap(long)]
    pub gateway_chain_id: u64,
}

// ── GrantWhitelist args ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct GrantWhitelistArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub common: ConvertShared,

    /// Addresses to whitelist on the gateway. Can be specified multiple times.
    #[clap(long, required = true)]
    pub whitelist_grantees: Vec<Address>,
}

// ── VotePrepare args ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct VotePrepareArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub common: ConvertShared,

    /// Chain ID of an existing chain under this CTM, used to introspect configuration.
    #[clap(long)]
    pub ctm_representative_chain_id: u64,

    /// CTM proxy address (used to dump force deployments data).
    /// If --force-deployments-data is provided, this is not required.
    #[clap(long)]
    pub ctm_proxy: Option<Address>,

    /// Path to the vote preparation output TOML, relative to l1-contracts root.
    #[clap(long, default_value = "script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_toml: String,

    /// Hex-encoded force deployments data.
    /// If omitted, automatically derived by running the dump-force-deployments forge script
    /// (requires --ctm-proxy).
    #[clap(long)]
    pub force_deployments_data: Option<String>,

    /// Refund recipient address.
    #[clap(long)]
    pub refund_recipient: Address,

    /// Fee charged by the gateway for settlement (in wei, default: 1 gwei).
    #[clap(long, default_value = "1000000000")]
    pub gateway_settlement_fee: u64,

    /// Use the testnet verifier instead of the production one.
    #[clap(long)]
    pub testnet_verifier: bool,

    /// Use ZKsync OS instead of the legacy VM.
    #[clap(long)]
    pub zksync_os: bool,
}

// ── GovernanceExecute args ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct GovernanceExecuteArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub common: ConvertShared,

    /// Path to the vote preparation TOML produced by the vote-prepare stage.
    #[clap(long, default_value = "script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_toml: String,

    /// Governance contract address.
    #[clap(long)]
    pub governance_address: Address,
}

// ── RevokeWhitelist args ───────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct RevokeWhitelistArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub common: ConvertShared,

    /// Address to revoke from whitelist (typically the deployer used during vote-prepare).
    #[clap(long)]
    pub revoke_address: Address,
}

// ── Dispatch ───────────────────────────────────────────────────────────────

pub async fn run(cmd: ConvertCommands) -> anyhow::Result<()> {
    match cmd {
        ConvertCommands::DeployFilterer(args) => run_deploy_filterer(args).await,
        ConvertCommands::GrantWhitelist(args) => run_grant_whitelist(args).await,
        ConvertCommands::VotePrepare(args) => run_vote_prepare(args).await,
        ConvertCommands::GovernanceExecute(args) => run_governance_execute(args).await,
        ConvertCommands::RevokeWhitelist(args) => run_revoke_whitelist(args).await,
    }
}

/// Convert a relative TOML path to the form expected by forge env vars (`/`-prefixed).
fn forge_env_path(rel: &str) -> String {
    format!("/{}", rel.trim_start_matches('/'))
}

// ── Step 1: Deploy filterer ------------------------------------------------

async fn run_deploy_filterer(args: DeployFiltererArgs) -> anyhow::Result<()> {
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
        format!("{:#x}", args.bridgehub),
        args.gateway_chain_id.to_string(),
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
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub));
    logger::info(format!("Gateway chain ID: {}", args.gateway_chain_id));

    runner
        .run(script)
        .context("forge DeployAndSetGatewayTransactionFilterer")?;

    write_output_if_requested(
        "chain.gateway.convert.deploy-filterer",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &serde_json::json!({
            "bridgehub": format!("{:#x}", args.bridgehub),
            "gateway_chain_id": args.gateway_chain_id,
        }),
    )
    .await?;

    logger::success("Gateway transaction filterer deployed");
    Ok(())
}

// ── Step 2: Grant whitelist ------------------------------------------------

async fn run_grant_whitelist(args: GrantWhitelistArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.common.shared.private_key, args.common.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.common.shared.simulate,
        &args.common.shared.l1_rpc_url,
        args.common.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::resolve_l1_contracts_path()?;
    let script_path = "deploy-scripts/AdminFunctions.s.sol";

    // Encode grantees as a Solidity address[] literal: [addr1,addr2,...]
    let grantees_str = format!(
        "[{}]",
        args.whitelist_grantees
            .iter()
            .map(|a| format!("{a:#x}"))
            .collect::<Vec<_>>()
            .join(",")
    );

    let mut script_args = args.common.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "grantGatewayWhitelist(address,uint256,address[],bool)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend([
        format!("{:#x}", args.common.bridgehub),
        args.common.gateway_chain_id.to_string(),
        grantees_str,
        "true".to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(&sender, runner.simulate);

    logger::step("Granting gateway whitelist");
    logger::info(format!(
        "Gateway chain ID: {}",
        args.common.gateway_chain_id
    ));
    logger::info(format!("Grantees: {}", args.whitelist_grantees.len()));

    runner
        .run(script)
        .context("Failed to grant gateway whitelist")?;

    write_stage_output(&runner, &args.common, "grant-whitelist").await?;

    logger::success("Gateway whitelist granted");
    Ok(())
}

// ── Step 3: Vote preparation -----------------------------------------------

/// Dump force deployments data by running the read-only forge script.
/// Returns the hex-encoded force_deployments_data string.
fn dump_force_deployments(runner: &mut ForgeRunner, ctm_proxy: Address) -> anyhow::Result<String> {
    let contracts_path = paths::path_to_foundry_scripts();
    std::fs::create_dir_all(contracts_path.join("script-out"))
        .context("create l1-contracts/script-out")?;

    let dump_toml_rel = "/script-out/force-deployments-dump.toml";

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "run(address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args
        .additional_args
        .push(format!("{:#x}", ctm_proxy));

    let script = Forge::new(&contracts_path)
        .script(
            Path::new(
                "deploy-scripts/dev/DumpForceDeploymentsForGateway.s.sol:DumpForceDeploymentsForGateway",
            ),
            script_args,
        )
        .with_env("FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH", dump_toml_rel);

    logger::info(format!(
        "Dumping force deployments (CTM proxy: {:#x})",
        ctm_proxy
    ));
    runner
        .run(script)
        .context("forge DumpForceDeploymentsForGateway")?;

    // Read the dumped TOML and extract force_deployments_data
    let dump_path = contracts_path.join(dump_toml_rel.trim_start_matches('/'));
    let toml_content = std::fs::read_to_string(&dump_path).with_context(|| {
        format!(
            "Failed to read force deployments dump: {}",
            dump_path.display()
        )
    })?;

    #[derive(Deserialize)]
    struct DumpOutput {
        force_deployments_data: String,
    }
    let output: DumpOutput =
        toml::from_str(&toml_content).context("Failed to parse force deployments dump TOML")?;

    Ok(output.force_deployments_data)
}

async fn run_vote_prepare(args: VotePrepareArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.common.shared.private_key, args.common.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.common.shared.simulate,
        &args.common.shared.l1_rpc_url,
        args.common.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::resolve_l1_contracts_path()?;

    // Resolve force_deployments_data: use explicit override or dump from chain.
    let force_deployments_data = match args.force_deployments_data {
        Some(fd) => fd,
        None => {
            let ctm_proxy = args
                .ctm_proxy
                .context("--ctm-proxy is required when --force-deployments-data is not provided")?;
            dump_force_deployments(&mut runner, ctm_proxy)?
        }
    };

    // Build the vote preparation input TOML from CLI args.
    let toml_content = format!(
        r#"# Used by the gateway vote preparation forge script
testnet_verifier = {testnet_verifier}
is_zk_sync_os = {zksync_os}
refund_recipient = "{refund:#x}"
gateway_chain_id = {gw}
gateway_settlement_fee = {fee}
force_deployments_data = "{fd}"

# Not used by the gateway flow but required by the parent config parser (overridden from on-chain state)
owner_address = "0x0000000000000000000000000000000000000000"
support_l2_legacy_shared_bridge_test = false
zk_token_asset_id = "0x0000000000000000000000000000000000000000000000000000000000000001"

[contracts]
create2_factory_salt = "0x0000000000000000000000000000000000000000000000000000000000000000"
governance_security_council_address = "0x0000000000000000000000000000000000000000"
governance_min_delay = 0
validator_timelock_execution_delay = 0
"#,
        refund = args.refund_recipient,
        testnet_verifier = args.testnet_verifier,
        zksync_os = args.zksync_os,
        gw = args.common.gateway_chain_id,
        fee = args.gateway_settlement_fee,
        fd = force_deployments_data,
    );

    let script_config = contracts_path.join("script-config");
    std::fs::create_dir_all(&script_config)?;

    let generated_rel = "script-config/gateway-vote-preparation-generated.toml";
    let abs_path = contracts_path.join(generated_rel);
    std::fs::write(&abs_path, &toml_content)?;

    let script_path = "deploy-scripts/gateway/GatewayVotePreparation.s.sol";
    let script_full_path = contracts_path.join(script_path);
    anyhow::ensure!(
        script_full_path.exists(),
        "Script not found: {}",
        script_full_path.display()
    );

    let mut script_args = args.common.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "run(address,uint256)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::Slow);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT,
    });
    script_args.additional_args.extend([
        format!("{:#x}", args.common.bridgehub),
        args.ctm_representative_chain_id.to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_env(
            "GATEWAY_VOTE_PREPARATION_INPUT",
            forge_env_path(generated_rel),
        )
        .with_env(
            "GATEWAY_VOTE_PREPARATION_OUTPUT",
            forge_env_path(&args.vote_preparation_toml),
        )
        .with_wallet(&sender, runner.simulate);

    logger::step("Running gateway vote preparation");
    logger::info(format!("Bridgehub: {:#x}", args.common.bridgehub));
    logger::info(format!(
        "CTM representative chain ID: {}",
        args.ctm_representative_chain_id
    ));
    logger::info(format!(
        "Gateway chain ID: {}",
        args.common.gateway_chain_id
    ));

    runner
        .run(script)
        .context("Failed to run gateway vote preparation")?;

    // Read the output TOML for the combined output.
    // Strip leading '/' so that PathBuf::join treats it as relative to contracts_path
    // (forge uses /-prefixed paths relative to the project root, but on the host
    // filesystem we need to join against the resolved contracts directory).
    let output_path = contracts_path.join(args.vote_preparation_toml.trim_start_matches('/'));
    let output_toml = std::fs::read_to_string(&output_path).with_context(|| {
        format!(
            "Failed to read vote preparation output: {}",
            output_path.display()
        )
    })?;
    let output_json: Value = toml::from_str::<toml::Value>(&output_toml)
        .context("Failed to parse vote preparation output TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{e}")))?;

    let run_json = runner
        .runs()
        .last()
        .map(|r| r.payload.clone())
        .unwrap_or_else(|| Value::Object(Default::default()));

    #[derive(Serialize)]
    struct VotePrepareOutput<'a> {
        vote_preparation: &'a Value,
        run_json: Value,
    }
    write_output_if_requested(
        "chain.gateway.convert.vote-prepare",
        &args.common.shared,
        &runner,
        &serde_json::json!({"stage": "vote-prepare"}),
        &VotePrepareOutput {
            vote_preparation: &output_json,
            run_json,
        },
    )
    .await?;

    logger::success("Gateway vote preparation complete");
    logger::info(format!("Output written to: {}", output_path.display()));
    Ok(())
}

// ── Step 4: Governance execute ---------------------------------------------

#[derive(Debug, Deserialize)]
struct VotePreparationOutput {
    governance_calls_to_execute: String,
}

async fn run_governance_execute(args: GovernanceExecuteArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.common.shared.private_key, args.common.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.common.shared.simulate,
        &args.common.shared.l1_rpc_url,
        args.common.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::resolve_l1_contracts_path()?;

    // Read the vote preparation output to get encoded governance calls
    let output_path = contracts_path.join(args.vote_preparation_toml.trim_start_matches('/'));
    let toml_content = std::fs::read_to_string(&output_path).with_context(|| {
        format!(
            "Failed to read vote preparation output: {}. Run vote-prepare stage first.",
            output_path.display()
        )
    })?;
    let output: VotePreparationOutput =
        toml::from_str(&toml_content).context("Failed to parse vote preparation output TOML")?;

    let encoded_calls_hex = &output.governance_calls_to_execute;

    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = args.common.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "governanceExecuteCalls(bytes,address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT,
    });
    script_args.additional_args.extend([
        format!("0x{}", encoded_calls_hex.trim_start_matches("0x")),
        format!("{:#x}", args.governance_address),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(&sender, runner.simulate);

    logger::step("Executing gateway governance calls");
    logger::info(format!(
        "Governance address: {:#x}",
        args.governance_address
    ));

    runner
        .run(script)
        .context("Failed to execute gateway governance calls")?;

    write_stage_output(&runner, &args.common, "governance-execute").await?;

    logger::success("Gateway governance calls executed");
    Ok(())
}

// ── Step 5: Revoke whitelist -----------------------------------------------

async fn run_revoke_whitelist(args: RevokeWhitelistArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.common.shared.private_key, args.common.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.common.shared.simulate,
        &args.common.shared.l1_rpc_url,
        args.common.shared.forge_args.clone(),
    )?;

    let contracts_path = paths::resolve_l1_contracts_path()?;
    let script_path = "deploy-scripts/AdminFunctions.s.sol";

    let mut script_args = args.common.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "revokeGatewayWhitelist(address,uint256,address,bool)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend([
        format!("{:#x}", args.common.bridgehub),
        args.common.gateway_chain_id.to_string(),
        format!("{:#x}", args.revoke_address),
        "true".to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(&sender, runner.simulate);

    logger::step("Revoking gateway whitelist");
    logger::info(format!("Revoking address: {:#x}", args.revoke_address));

    runner
        .run(script)
        .context("Failed to revoke gateway whitelist")?;

    write_stage_output(&runner, &args.common, "revoke-whitelist").await?;

    logger::success("Gateway whitelist revoked");
    Ok(())
}

// ── Helpers ----------------------------------------------------------------

async fn write_stage_output(
    runner: &ForgeRunner,
    common: &ConvertShared,
    stage: &str,
) -> anyhow::Result<()> {
    #[derive(Serialize)]
    struct StageOutput<'a> {
        stage: &'a str,
        gateway_chain_id: u64,
    }
    write_output_if_requested(
        "chain.gateway.convert",
        &common.shared,
        runner,
        &serde_json::json!({"stage": stage}),
        &StageOutput {
            stage,
            gateway_chain_id: common.gateway_chain_id,
        },
    )
    .await
}
