use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
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

/// Stages for the gateway conversion process.
#[derive(Debug, Clone, Copy, clap::ValueEnum, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ConvertToGatewayStage {
    /// Step 1: Grant deployer whitelist on the gateway chain's transaction filterer.
    GrantWhitelist,
    /// Step 2: Deploy gateway CTM contracts and prepare governance calls.
    VotePrepare,
    /// Step 3: Execute governance calls from the vote preparation output.
    GovernanceExecute,
    /// Step 4: Revoke deployer whitelist after deployment is complete.
    RevokeWhitelist,
}

impl std::fmt::Display for ConvertToGatewayStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::GrantWhitelist => write!(f, "grant-whitelist"),
            Self::VotePrepare => write!(f, "vote-prepare"),
            Self::GovernanceExecute => write!(f, "governance-execute"),
            Self::RevokeWhitelist => write!(f, "revoke-whitelist"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ConvertToGatewayArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Conversion stage to execute.
    #[clap(long, value_enum)]
    pub stage: ConvertToGatewayStage,

    /// Bridgehub proxy address.
    #[clap(long)]
    pub bridgehub_proxy_address: Address,

    /// Gateway chain ID (the chain being converted to a gateway).
    #[clap(long)]
    pub gateway_chain_id: u64,

    /// Addresses to whitelist on the gateway (required for grant-whitelist stage).
    /// Can be specified multiple times.
    #[clap(long)]
    pub whitelist_grantees: Vec<Address>,

    /// CTM representative chain ID (required for vote-prepare stage).
    /// Used to introspect the existing CTM for configuration.
    #[clap(long)]
    pub ctm_representative_chain_id: Option<u64>,

    /// Path to the gateway vote preparation output TOML, relative to l1-contracts root.
    #[clap(long, default_value = "/script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_output_path: String,

    /// Hex-encoded force deployments data (required for vote-prepare stage).
    #[clap(long)]
    pub force_deployments_data: Option<String>,

    /// Refund recipient address (required for vote-prepare stage).
    #[clap(long)]
    pub refund_recipient: Option<Address>,

    /// Gateway settlement fee (default: 1000000000).
    #[clap(long, default_value = "1000000000")]
    pub gateway_settlement_fee: u64,

    /// Whether to use testnet verifier (required for vote-prepare stage).
    #[clap(long)]
    pub testnet_verifier: Option<bool>,

    /// Whether to use ZKsync OS (required for vote-prepare stage).
    #[clap(long)]
    pub is_zk_sync_os: Option<bool>,

    /// Governance address (required for governance-execute stage).
    #[clap(long)]
    pub governance_address: Option<Address>,

    /// Address to revoke from whitelist (required for revoke-whitelist stage).
    /// Typically the deployer address used during vote-prepare.
    #[clap(long)]
    pub revoke_address: Option<Address>,
}

pub async fn run(args: ConvertToGatewayArgs) -> anyhow::Result<()> {
    let sender = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    match args.stage {
        ConvertToGatewayStage::GrantWhitelist => run_grant_whitelist(&mut runner, &sender, &args),
        ConvertToGatewayStage::VotePrepare => run_vote_prepare(&mut runner, &sender, &args),
        ConvertToGatewayStage::GovernanceExecute => {
            run_governance_execute(&mut runner, &sender, &args)
        }
        ConvertToGatewayStage::RevokeWhitelist => run_revoke_whitelist(&mut runner, &sender, &args),
    }
}

fn resolve_l1_contracts_path() -> anyhow::Result<PathBuf> {
    paths::resolve_l1_contracts_path()
}

// ─── Step 1: Grant whitelist ─────────────────────────────────────────────────

fn run_grant_whitelist(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &ConvertToGatewayArgs,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        !args.whitelist_grantees.is_empty(),
        "--whitelist-grantees is required for grant-whitelist stage"
    );

    let contracts_path = resolve_l1_contracts_path()?;
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

    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "grantGatewayWhitelist(address,uint256,address[],bool)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend([
        format!("{:#x}", args.bridgehub_proxy_address),
        args.gateway_chain_id.to_string(),
        grantees_str,
        "true".to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender, runner.simulate);

    logger::step("Granting gateway whitelist");
    logger::info(format!("Gateway chain ID: {}", args.gateway_chain_id));
    logger::info(format!("Grantees: {}", args.whitelist_grantees.len()));

    runner
        .run(script)
        .context("Failed to grant gateway whitelist")?;

    write_stage_output(runner, args, "grant-whitelist")?;

    logger::success("Gateway whitelist granted");
    Ok(())
}

// ─── Step 2: Vote preparation ────────────────────────────────────────────────

fn run_vote_prepare(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &ConvertToGatewayArgs,
) -> anyhow::Result<()> {
    let ctm_chain_id = args.ctm_representative_chain_id.ok_or_else(|| {
        anyhow::anyhow!("--ctm-representative-chain-id is required for vote-prepare stage")
    })?;

    let contracts_path = resolve_l1_contracts_path()?;

    let force_hex = args.force_deployments_data.as_deref().ok_or_else(|| {
        anyhow::anyhow!("--force-deployments-data is required for vote-prepare stage")
    })?;
    let refund = args.refund_recipient.ok_or_else(|| {
        anyhow::anyhow!("--refund-recipient is required for vote-prepare stage")
    })?;
    let testnet_verifier = args.testnet_verifier.ok_or_else(|| {
        anyhow::anyhow!("--testnet-verifier is required for vote-prepare stage")
    })?;
    let is_zk_sync_os = args.is_zk_sync_os.ok_or_else(|| {
        anyhow::anyhow!("--is-zk-sync-os is required for vote-prepare stage")
    })?;

    // Build the vote preparation input TOML from CLI args.
    // The forge script (GatewayVotePreparation) reads these fields; values
    // like owner_address are overridden from on-chain state, and contracts.*
    // fields are not used in the gateway flow but the parent parser requires them.
    let toml_content = format!(
        r#"# Used by the gateway vote preparation forge script
testnet_verifier = {testnet_verifier}
is_zk_sync_os = {is_zk_sync_os}
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
        refund = refund,
        testnet_verifier = testnet_verifier,
        is_zk_sync_os = is_zk_sync_os,
        gw = args.gateway_chain_id,
        fee = args.gateway_settlement_fee,
        fd = force_hex,
    );

    let script_config = contracts_path.join("script-config");
    std::fs::create_dir_all(&script_config)?;

    let generated_path = "/script-config/gateway-vote-preparation-generated.toml";
    let abs_path = contracts_path.join(generated_path.trim_start_matches('/'));
    std::fs::write(&abs_path, &toml_content)?;

    let vote_input_path = generated_path.to_string();

    let script_path = "deploy-scripts/gateway/GatewayVotePreparation.s.sol";
    let script_full_path = contracts_path.join(script_path);
    anyhow::ensure!(
        script_full_path.exists(),
        "Script not found: {}",
        script_full_path.display()
    );

    let mut script_args = args.shared.forge_args.clone();
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
        format!("{:#x}", args.bridgehub_proxy_address),
        ctm_chain_id.to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_env(
            "GATEWAY_VOTE_PREPARATION_INPUT",
            &vote_input_path,
        )
        .with_env(
            "GATEWAY_VOTE_PREPARATION_OUTPUT",
            &args.vote_preparation_output_path,
        )
        .with_wallet(sender, runner.simulate);

    logger::step("Running gateway vote preparation");
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub_proxy_address));
    logger::info(format!("CTM representative chain ID: {}", ctm_chain_id));
    logger::info(format!("Gateway chain ID: {}", args.gateway_chain_id));

    runner
        .run(script)
        .context("Failed to run gateway vote preparation")?;

    // Read the output TOML for the combined output
    let output_path =
        contracts_path.join(args.vote_preparation_output_path.trim_start_matches('/'));
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
        "chain.convert-to-gateway",
        args.shared.out_path.as_deref(),
        args.shared.safe_transactions_out.as_deref(),
        runner,
        &serde_json::json!({"stage": "vote-prepare"}),
        &VotePrepareOutput {
            vote_preparation: &output_json,
            run_json,
        },
    )?;

    logger::success("Gateway vote preparation complete");
    logger::info(format!("Output written to: {}", output_path.display()));
    Ok(())
}

// ─── Step 3: Governance execute ──────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct VotePreparationOutput {
    governance_calls_to_execute: String,
}

fn run_governance_execute(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &ConvertToGatewayArgs,
) -> anyhow::Result<()> {
    let governance_addr = args.governance_address.ok_or_else(|| {
        anyhow::anyhow!("--governance-address is required for governance-execute stage")
    })?;

    let contracts_path = resolve_l1_contracts_path()?;

    // Read the vote preparation output to get encoded governance calls
    let output_path =
        contracts_path.join(args.vote_preparation_output_path.trim_start_matches('/'));
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
    let mut script_args = args.shared.forge_args.clone();
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
        format!("{:#x}", governance_addr),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender, runner.simulate);

    logger::step("Executing gateway governance calls");
    logger::info(format!("Governance address: {:#x}", governance_addr));

    runner
        .run(script)
        .context("Failed to execute gateway governance calls")?;

    write_stage_output(runner, args, "governance-execute")?;

    logger::success("Gateway governance calls executed");
    Ok(())
}

// ─── Step 4: Revoke whitelist ────────────────────────────────────────────────

fn run_revoke_whitelist(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    args: &ConvertToGatewayArgs,
) -> anyhow::Result<()> {
    let revoke_addr = args.revoke_address.ok_or_else(|| {
        anyhow::anyhow!("--revoke-address is required for revoke-whitelist stage")
    })?;

    let contracts_path = resolve_l1_contracts_path()?;
    let script_path = "deploy-scripts/AdminFunctions.s.sol";

    let mut script_args = args.shared.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "revokeGatewayWhitelist(address,uint256,address,bool)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.additional_args.extend([
        format!("{:#x}", args.bridgehub_proxy_address),
        args.gateway_chain_id.to_string(),
        format!("{:#x}", revoke_addr),
        "true".to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender, runner.simulate);

    logger::step("Revoking gateway whitelist");
    logger::info(format!("Revoking address: {:#x}", revoke_addr));

    runner
        .run(script)
        .context("Failed to revoke gateway whitelist")?;

    write_stage_output(runner, args, "revoke-whitelist")?;

    logger::success("Gateway whitelist revoked");
    Ok(())
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn write_stage_output(
    runner: &ForgeRunner,
    args: &ConvertToGatewayArgs,
    stage: &str,
) -> anyhow::Result<()> {
    #[derive(Serialize)]
    struct StageOutput<'a> {
        stage: &'a str,
        gateway_chain_id: u64,
    }
    write_output_if_requested(
        "chain.convert-to-gateway",
        args.shared.out_path.as_deref(),
        args.shared.safe_transactions_out.as_deref(),
        runner,
        &serde_json::json!({"stage": stage}),
        &StageOutput {
            stage,
            gateway_chain_id: args.gateway_chain_id,
        },
    )
}
