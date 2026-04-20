use std::path::Path;

use anyhow::Context;
use clap::Parser;
use ethers::types::Address;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::commands::output::write_output_if_requested;
use crate::common::paths;
use crate::common::EcosystemChainArgs;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner, ForgeScriptArg},
    logger,
    wallets::Wallet,
};

use super::build_admin_functions_script;

/// Convert a relative TOML path to the form expected by forge env vars (`/`-prefixed).
fn forge_env_path(rel: &str) -> String {
    format!("/{}", rel.trim_start_matches('/'))
}

// ── Step 1: Deploy filterer ------------------------------------------------

/// Run deploy-filterer on an existing `runner` with `sender` already prepared
/// (must be the chain admin owner EOA). Reusable from the fine-grained CLI
/// entry point and the phase-level `chain gateway convert` command.
pub(crate) async fn stage_deploy_filterer(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let contracts_path = paths::path_to_foundry_scripts();

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "deployAndSetOnChain(address,uint256)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args
        .additional_args
        .extend([format!("{:#x}", bridgehub), chain_id.to_string()]);

    let script = Forge::new(&contracts_path)
        .script(
            Path::new(
                "deploy-scripts/gateway/DeployGatewayTransactionFilterer.s.sol:DeployGatewayTransactionFilterer",
            ),
            script_args,
        )
        .with_wallet(sender);

    logger::step("Deploying gateway transaction filterer");
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Gateway chain ID: {}", chain_id));

    runner
        .run(script)
        .context("forge DeployGatewayTransactionFilterer::deployAndSetOnChain")?;

    logger::success("Gateway transaction filterer deployed");
    Ok(())
}

// ── Step 2: Grant whitelist ------------------------------------------------

/// Run grant-whitelist on an existing `runner`. `sender` must be the chain
/// admin owner EOA. Auto-includes the CTM deployment tracker and governance
/// address in the whitelist in addition to `extra_grantees`.
pub(crate) async fn stage_grant_whitelist(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    bridgehub: Address,
    chain_id: u64,
    extra_grantees: &[Address],
) -> anyhow::Result<()> {
    let contracts_path = paths::resolve_l1_contracts_path()?;
    // Always broadcast the admin call, including in `--simulate`. The simulate
    // fork is ephemeral, so broadcasting has no real-world side effect — but
    // the Safe bundle is built from forge's broadcast log, so the tx must be
    // in there for downstream replay. The legacy `should_send=false` path
    // (calldata-only, no broadcast) is a dead end for our flow.
    //
    // TODO: `saveAndSendAdminTx` → `Utils.adminExecuteCalls(admin, address(0), calls)`
    // passes `address(0)` for the AccessControlRestriction, so the inner
    // `vm.startBroadcast` uses `ChainAdmin.owner()` as the sender. That only
    // works on chains without an ACR wired into `ChainAdmin.activeRestrictions`
    // (true for our local anvil fixtures, not for production-style setups). For
    // a real chain, we need to thread the ACR address through so the broadcast
    // goes out as `IAccessControlDefaultAdminRules(acr).defaultAdmin()`, which
    // is the account guaranteed to pass every selector's role check.
    let should_send = "true".to_string();

    // Auto-resolve the CTM deployment tracker (STM tracker) from the bridgehub
    // and include it in the whitelist — it must be whitelisted on the gateway so
    // CTM registration can proceed during vote-prepare.
    // Auto-resolve addresses that always need to be whitelisted on the
    // gateway for the convert flow to succeed.
    let stm_tracker = crate::common::l1_contracts::resolve_stm_tracker(&runner.rpc_url, bridgehub)
        .await
        .context("Failed to resolve CTM deployment tracker from bridgehub")?;
    logger::info(format!(
        "CTM deployment tracker (auto-resolved): {:#x}",
        stm_tracker
    ));

    let governance = crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
        .await
        .context("Failed to resolve governance address from bridgehub")?;
    logger::info(format!("Governance (auto-resolved): {:#x}", governance));

    let mut all_grantees: Vec<Address> = extra_grantees.to_vec();
    for addr in [stm_tracker, governance] {
        if !all_grantees.contains(&addr) {
            all_grantees.push(addr);
        }
    }

    // Encode grantees as a Solidity address[] literal: [addr1,addr2,...]
    let grantees_str = format!(
        "[{}]",
        all_grantees
            .iter()
            .map(|a| format!("{a:#x}"))
            .collect::<Vec<_>>()
            .join(",")
    );

    let script = build_admin_functions_script(
        &contracts_path,
        runner,
        "grantGatewayWhitelist(address,uint256,address[],bool)",
        vec![
            format!("{:#x}", bridgehub),
            chain_id.to_string(),
            grantees_str,
            should_send,
        ],
    )?
    .with_wallet(sender);

    logger::step("Granting gateway whitelist");
    logger::info(format!("Gateway chain ID: {}", chain_id));
    logger::info(format!("Grantees: {}", all_grantees.len()));

    runner
        .run(script)
        .context("Failed to grant gateway whitelist")?;

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
        sig: "dumpForceDeployments(address)".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args
        .additional_args
        .push(format!("{:#x}", ctm_proxy));

    let script = Forge::new(&contracts_path)
        .script(
            Path::new("deploy-scripts/gateway/GatewayUtils.s.sol:GatewayUtils"),
            script_args,
        )
        .with_env("FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH", dump_toml_rel);

    logger::info(format!(
        "Dumping force deployments (CTM proxy: {:#x})",
        ctm_proxy
    ));
    runner
        .run(script)
        .context("forge GatewayUtils::dumpForceDeployments")?;

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

/// Inputs for the vote-prepare stage.
pub(crate) struct VotePrepareInputs<'a> {
    pub ctm_representative_chain_id: u64,
    pub vote_preparation_toml: &'a str,
    pub refund_recipient: Address,
    pub gateway_settlement_fee: u64,
}

/// Run vote-prepare on an existing `runner`. `sender` must be the whitelisted
/// deployer EOA (= `refund_recipient`) — the script deploys gateway CTM
/// contracts and pays for L1→L2 priority txs from that EOA's balance.
pub(crate) async fn stage_vote_prepare(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    bridgehub: Address,
    chain_id: u64,
    inputs: &VotePrepareInputs<'_>,
) -> anyhow::Result<Value> {
    let contracts_path = paths::resolve_l1_contracts_path()?;

    // Resolve CTM proxy from bridgehub using the representative chain.
    let ctm_proxy = crate::common::l1_contracts::resolve_ctm_proxy(
        &runner.rpc_url,
        bridgehub,
        inputs.ctm_representative_chain_id,
    )
    .await
    .context("Failed to resolve CTM proxy from bridgehub")?;
    logger::info(format!("CTM proxy (from L1): {:#x}", ctm_proxy));

    // Dump force deployments data from the CTM.
    let force_deployments_data = dump_force_deployments(runner, ctm_proxy)?;

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
        refund = inputs.refund_recipient,
        testnet_verifier = {
            let v = crate::common::l1_contracts::resolve_is_testnet_verifier(
                &runner.rpc_url,
                ctm_proxy,
            )
            .await
            .context("Failed to resolve testnet verifier status")?;
            logger::info(format!("Testnet verifier (from L1): {v}"));
            v
        },
        zksync_os = {
            let v = crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm_proxy)
                .await
                .context("Failed to resolve isZKsyncOS from CTM")?;
            logger::info(format!("ZKsync OS (from L1): {v}"));
            v
        },
        gw = chain_id,
        fee = inputs.gateway_settlement_fee,
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

    let mut script_args = runner.forge_args.clone();
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "run(address,uint256)".to_string(),
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
        format!("{:#x}", bridgehub),
        inputs.ctm_representative_chain_id.to_string(),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_env(
            "GATEWAY_VOTE_PREPARATION_INPUT",
            forge_env_path(generated_rel),
        )
        .with_env(
            "GATEWAY_VOTE_PREPARATION_OUTPUT",
            forge_env_path(inputs.vote_preparation_toml),
        )
        .with_wallet(sender);

    logger::step("Running gateway vote preparation");
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!(
        "CTM representative chain ID: {}",
        inputs.ctm_representative_chain_id
    ));
    logger::info(format!("Gateway chain ID: {}", chain_id));

    runner
        .run(script)
        .context("Failed to run gateway vote preparation")?;

    // Read the output TOML for the combined output.
    // Strip leading '/' so that PathBuf::join treats it as relative to contracts_path
    // (forge uses /-prefixed paths relative to the project root, but on the host
    // filesystem we need to join against the resolved contracts directory).
    let output_path = contracts_path.join(inputs.vote_preparation_toml.trim_start_matches('/'));
    let output_toml = std::fs::read_to_string(&output_path).with_context(|| {
        format!(
            "Failed to read vote preparation output: {}",
            output_path.display()
        )
    })?;
    let output_json: Value = toml::from_str::<toml::Value>(&output_toml)
        .context("Failed to parse vote preparation output TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{e}")))?;

    logger::success("Gateway vote preparation complete");
    logger::info(format!("Output written to: {}", output_path.display()));
    Ok(output_json)
}

// ── Step 4: Governance execute ---------------------------------------------

#[derive(Debug, Deserialize)]
struct VotePreparationOutput {
    governance_calls_to_execute: String,
}

/// Run governance-execute on an existing `runner`. `sender` must be the
/// governance contract's owner EOA.
pub(crate) async fn stage_governance_execute(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    bridgehub: Address,
    vote_preparation_toml: &str,
) -> anyhow::Result<()> {
    let governance_address =
        crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
            .await
            .context("Failed to resolve governance address from bridgehub")?;
    logger::info(format!("Governance (from L1): {:#x}", governance_address));

    let contracts_path = paths::resolve_l1_contracts_path()?;

    // Read the vote preparation output to get encoded governance calls.
    let output_path = contracts_path.join(vote_preparation_toml.trim_start_matches('/'));
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
    let mut script_args = runner.forge_args.clone();
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
        format!("{:#x}", governance_address),
    ]);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender);

    logger::step("Executing gateway governance calls");
    logger::info(format!("Governance address: {:#x}", governance_address));

    runner
        .run(script)
        .context("Failed to execute gateway governance calls")?;

    logger::success("Gateway governance calls executed");
    Ok(())
}

// ── Step 5: Revoke whitelist -----------------------------------------------

/// Run revoke-whitelist on an existing `runner`. `sender` must be the chain
/// admin owner EOA.
pub(crate) async fn stage_revoke_whitelist(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    bridgehub: Address,
    chain_id: u64,
    revoke_address: Address,
) -> anyhow::Result<()> {
    let contracts_path = paths::resolve_l1_contracts_path()?;
    // See grant-whitelist for the rationale — always broadcast in simulate too
    // so the tx shows up in the bundle's --out / Safe file.
    //
    // TODO: same AccessControlRestriction caveat as grant-whitelist applies:
    // `Utils.adminExecuteCalls(admin, address(0), calls)` broadcasts as
    // `ChainAdmin.owner()`, which only works on chains without an ACR in
    // `activeRestrictions`. Thread the ACR address through for production
    // chains so the sender is the ACR's `defaultAdmin`.
    let should_send = "true".to_string();

    let script = build_admin_functions_script(
        &contracts_path,
        runner,
        "revokeGatewayWhitelist(address,uint256,address,bool)",
        vec![
            format!("{:#x}", bridgehub),
            chain_id.to_string(),
            format!("{:#x}", revoke_address),
            should_send,
        ],
    )?
    .with_wallet(sender);

    logger::step("Revoking gateway whitelist");
    logger::info(format!("Revoking address: {:#x}", revoke_address));

    runner
        .run(script)
        .context("Failed to revoke gateway whitelist")?;

    logger::success("Gateway whitelist revoked");
    Ok(())
}

// ════════════════════════════════════════════════════════════════════════
// Phase command: `chain gateway convert`
//
// Runs all five stages on a single anvil fork:
//   1. deploy-filterer       (chain admin)
//   2. grant-whitelist       (chain admin)
//   3. vote-prepare          (whitelisted deployer)
//   4. governance-execute    (governance owner)
//   5. revoke-whitelist      (chain admin)
//
// The emitted Safe bundle directory contains one `.safe.json` per consecutive
// same-signer group (so 4 files: admin+admin merged, deployer, governance,
// admin) plus a `manifest.json` listing them in apply order.
// ════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ConvertArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: EcosystemChainArgs,

    /// EOA whitelisted during vote-prepare and revoked after the governance
    /// stage. Also used as the refund recipient for L1→L2 priority txs. The
    /// EOA must hold enough L1 base-token balance to pay for those txs.
    /// Typically the ecosystem deployer.
    #[clap(long)]
    pub gateway_deployer: Address,

    /// Chain ID of an existing chain under this CTM, used by vote-prepare
    /// to introspect CTM configuration.
    #[clap(long)]
    pub ctm_representative_chain_id: u64,

    /// Path to the vote preparation output TOML, relative to l1-contracts
    /// root. Produced by stage 3 (vote-prepare), consumed by stage 4
    /// (governance-execute). Must live under `script-out/` due to forge
    /// fs_permissions.
    #[clap(long, default_value = "script-out/gateway-vote-preparation.toml")]
    pub vote_preparation_toml: String,

    /// Fee charged by the gateway for settlement (in wei, default: 1 gwei).
    #[clap(long, default_value = "1000000000")]
    pub gateway_settlement_fee: u64,
}

pub async fn run_convert(args: ConvertArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve_bridgehub()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    // Stages 1 + 2: chain admin owner.
    let admin_sender = runner
        .prepare_chain_admin_owner(bridgehub, chain_id)
        .await?;
    let admin_owner = admin_sender.address;
    stage_deploy_filterer(&mut runner, &admin_sender, bridgehub, chain_id)
        .await
        .context("convert stage 1 (deploy-filterer)")?;
    stage_grant_whitelist(
        &mut runner,
        &admin_sender,
        bridgehub,
        chain_id,
        &[args.gateway_deployer],
    )
    .await
    .context("convert stage 2 (grant-whitelist)")?;

    // Stage 3: whitelisted deployer EOA (gateway_deployer).
    let deployer_sender = runner.prepare_sender(args.gateway_deployer).await?;
    let vote_output_json = stage_vote_prepare(
        &mut runner,
        &deployer_sender,
        bridgehub,
        chain_id,
        &VotePrepareInputs {
            ctm_representative_chain_id: args.ctm_representative_chain_id,
            vote_preparation_toml: &args.vote_preparation_toml,
            refund_recipient: args.gateway_deployer,
            gateway_settlement_fee: args.gateway_settlement_fee,
        },
    )
    .await
    .context("convert stage 3 (vote-prepare)")?;

    // Stage 4: governance owner EOA.
    let gov_sender = runner.prepare_governance_owner(bridgehub).await?;
    stage_governance_execute(
        &mut runner,
        &gov_sender,
        bridgehub,
        &args.vote_preparation_toml,
    )
    .await
    .context("convert stage 4 (governance-execute)")?;

    // Stage 5: chain admin owner again (re-impersonate).
    let admin_sender = runner.prepare_sender(admin_owner).await?;
    stage_revoke_whitelist(
        &mut runner,
        &admin_sender,
        bridgehub,
        chain_id,
        args.gateway_deployer,
    )
    .await
    .context("convert stage 5 (revoke-whitelist)")?;

    #[derive(Serialize)]
    struct ConvertOutput<'a> {
        chain_id: u64,
        gateway_deployer: String,
        vote_preparation: &'a Value,
    }
    write_output_if_requested(
        "chain.gateway.convert",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &ConvertOutput {
            chain_id,
            gateway_deployer: format!("{:#x}", args.gateway_deployer),
            vote_preparation: &vote_output_json,
        },
    )
    .await
}
