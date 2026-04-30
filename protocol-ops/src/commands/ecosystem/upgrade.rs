//! Ecosystem-level v31 upgrade flow.
//!
//! Two top-level commands:
//!
//!   `upgrade-prepare`     deploys new ecosystem contracts (deployer EOA signs).
//!   `upgrade-governance`  runs governance stages 0 + 1 + 2 on one anvil fork
//!                         and emits one Safe bundle (governance owner signs).
//!
//! Stage 2 (unpause migrations) is bundled with stages 0+1 even though the
//! original upgrade flow ran it after the chain upgrade. Bundling means the
//! stage-2 simulation happens against a pre-chain-upgrade L1 fork, which is
//! fine because the unpause-migrations call doesn't depend on v31-only state.
//! Signers get one Safe bundle to approve instead of two separate ones, with
//! no temporal coordination on the multisig side.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::abi_contracts::UPGRADE_V31_CONTRACT;
use crate::commands::ecosystem::v31_upgrade_full::V31UpgradeFull;
use crate::commands::ecosystem::v31_upgrade_inner::V31UpgradeInner;
use crate::commands::output::write_output_if_requested;
use crate::common::paths;
use crate::common::SharedRunArgs;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::config::forge_interface::script_params::{
    ADMIN_FUNCTIONS_INVOCATION, ECOSYSTEM_UPGRADE_V31_SCRIPT_PATH, UPGRADE_V31_CORE_OUTPUT_PATH,
    UPGRADE_V31_CTM_OUTPUT_PATH, UPGRADE_V31_ECOSYSTEM_OUTPUT_PATH,
    UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH,
};

// ── upgrade-prepare ───────────────────────────────────────────────────────

/// Deploy new ecosystem contracts (ChainAssetHandler, NativeTokenVault, …)
/// for a v31 upgrade. Signed by a deployer EOA. Emits a Safe bundle and a
/// `governance.toml` containing the encoded calls that
/// [`UpgradeGovernanceArgs`] later replays.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct UpgradePrepareArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Deployer EOA that signs the new-contract deployment txs emitted by
    /// this stage.
    #[clap(long)]
    pub deployer_address: Address,

    // The following are auto-resolved from L1 on v31+ ecosystems.
    // Explicit overrides are only needed when upgrading from pre-v31 protocol
    // versions where the on-chain getters don't exist yet.
    // TODO(v30-removal): remove these once v30 upgrades are no longer supported.
    /// Bytecodes supplier address. Auto-resolved from CTM on v31+.
    #[clap(long)]
    pub bytecodes_supplier_address: Option<Address>,
    /// Rollup DA manager address. Auto-resolved from ZK chain on v31+.
    #[clap(long)]
    pub rollup_da_manager_address: Option<Address>,
    /// Whether target chain is ZKsync OS. Auto-resolved from CTM on v31+.
    #[clap(long)]
    pub is_zk_sync_os: Option<bool>,

    /// CREATE2 factory salt (hex-encoded bytes32). If not provided, a random salt is used.
    #[clap(long)]
    pub create2_factory_salt: Option<H256>,

    /// CTM proxy override. When set, the upgrade is prepared against this CTM
    /// instead of auto-resolving via the first registered chain. Required when
    /// the ecosystem hosts multiple CTMs (e.g. EVM + zkOS) and the caller wants
    /// to target a specific one. Auto-resolution must still find a registered
    /// chain that uses this CTM, otherwise other addresses (rollup DA manager,
    /// etc.) cannot be resolved.
    #[clap(long)]
    pub ctm_proxy: Option<Address>,

    /// Forge-internal: upgrade config TOML path relative to l1-contracts root.
    /// Passed through to the Solidity script; rarely needs overriding.
    #[clap(
        long,
        default_value = UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH,
        hide = true
    )]
    pub upgrade_input_path: String,

    /// Forge-internal: ecosystem output TOML path relative to l1-contracts root.
    /// Passed through to the Solidity script; rarely needs overriding.
    #[clap(
        long,
        default_value = UPGRADE_V31_ECOSYSTEM_OUTPUT_PATH,
        hide = true
    )]
    pub upgrade_output_path: String,

    /// Write the governance calls TOML to this path (consumed by the
    /// downstream `upgrade-governance` command).
    #[clap(long)]
    pub governance_toml_out: Option<PathBuf>,

    /// Forge-internal: ecosystem upgrade script path.
    ///
    /// Hidden because production callers should use the default script. Test
    /// harnesses may override this with a subclass that keeps the same
    /// `noGovernancePrepare(...)` entry point but trims non-essential output
    /// to stay within local Anvil/Forge memory limits.
    #[clap(
        long,
        default_value = ECOSYSTEM_UPGRADE_V31_SCRIPT_PATH,
        hide = true
    )]
    pub script_path: String,
}

#[derive(Serialize)]
struct UpgradePrepareOutput<'a> {
    core: &'a Value,
    ecosystem: &'a Value,
    ctm: &'a Value,
    run_json: Value,
}

pub async fn run_upgrade_prepare(args: UpgradePrepareArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?.bridgehub;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(args.deployer_address).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let script_path = args.script_path.trim_start_matches('/');
    let script_file_path = script_path.split(':').next().unwrap_or(script_path);
    let script_full_path = contracts_path.join(script_file_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }

    // Auto-resolve contract addresses from L1.
    // CTM is always discoverable (even on v30). Other addresses may need
    // explicit overrides on pre-v31 ecosystems.
    let chain_ids = crate::common::l1_contracts::resolve_all_chain_ids(&runner.rpc_url, bridgehub)
        .await
        .context("Failed to query registered chain IDs from bridgehub")?;
    if chain_ids.is_empty() {
        anyhow::bail!("No chains registered on bridgehub");
    }

    // If a CTM proxy override is supplied, find a registered chain that uses
    // it; otherwise default to chain_ids[0]. The representative chain is used
    // to look up other ecosystem addresses (e.g. rollup DA manager) that vary
    // per-chain — picking one that actually sits behind the same CTM keeps
    // the auto-resolved values consistent with the targeted upgrade scope.
    let (representative_chain, ctm) = match args.ctm_proxy {
        Some(override_ctm) => {
            let mut found: Option<(u64, Address)> = None;
            for &cid in &chain_ids {
                let chain_ctm =
                    crate::common::l1_contracts::resolve_ctm_proxy(&runner.rpc_url, bridgehub, cid)
                        .await
                        .with_context(|| format!("resolving CTM for chain {cid}"))?;
                if chain_ctm == override_ctm {
                    found = Some((cid, chain_ctm));
                    break;
                }
            }
            let (cid, ctm) = found.with_context(|| {
                format!(
                    "No registered chain uses CTM {override_ctm:#x}; cannot pick a \
                     representative chain. Either register a chain on this CTM \
                     first or omit --ctm-proxy."
                )
            })?;
            logger::info(format!(
                "CTM proxy (override; matched via chain {cid}): {:#x}",
                ctm
            ));
            (cid, ctm)
        }
        None => {
            let cid = chain_ids[0];
            let ctm =
                crate::common::l1_contracts::resolve_ctm_proxy(&runner.rpc_url, bridgehub, cid)
                    .await
                    .context("Failed to resolve CTM proxy from bridgehub")?;
            logger::info(format!("CTM proxy (from L1 via chain {cid}): {:#x}", ctm));
            (cid, ctm)
        }
    };
    let bytecodes_supplier = match args.bytecodes_supplier_address {
        Some(addr) => addr,
        None => {
            let resolved =
                crate::common::l1_contracts::resolve_bytecodes_supplier(&runner.rpc_url, ctm)
                    .await
                    .context("Failed to auto-resolve bytecodes supplier from CTM")?;
            logger::info(format!(
                "Bytecodes supplier (auto-resolved): {:#x}",
                resolved
            ));
            resolved
        }
    };
    let is_zk_sync_os = match args.is_zk_sync_os {
        Some(v) => v,
        None => {
            let resolved = crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm)
                .await
                .context("Failed to resolve isZKsyncOS from CTM")?;
            logger::info(format!("ZKsync OS (auto-resolved): {resolved}"));
            resolved
        }
    };
    let rollup_da_manager = match args.rollup_da_manager_address {
        Some(addr) => addr,
        None => {
            let zk_chain = crate::common::l1_contracts::resolve_zk_chain(
                &runner.rpc_url,
                bridgehub,
                representative_chain,
            )
            .await
            .context("Failed to resolve ZK chain diamond proxy from bridgehub")?;
            let resolved =
                crate::common::l1_contracts::resolve_rollup_da_manager(&runner.rpc_url, zk_chain)
                    .await
                    .context("Failed to auto-resolve RollupDAManager from ZK chain")?;
            logger::info(format!(
                "RollupDAManager (auto-resolved via chain {representative_chain}): {:#x}",
                resolved
            ));
            resolved
        }
    };
    let governance = {
        let resolved = crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
            .await
            .context("Failed to auto-resolve governance address from bridgehub")?;
        logger::info(format!("Governance (auto-resolved): {:#x}", resolved));
        resolved
    };
    let create2_salt = args.create2_factory_salt.unwrap_or_else(H256::random);

    let upgrade_input = contracts_path.join(args.upgrade_input_path.trim_start_matches('/'));
    if !upgrade_input.exists() {
        anyhow::bail!("Upgrade input file not found: {}", upgrade_input.display());
    }

    // Remove existing script outputs so we only read fresh results from this run.
    let script_out = contracts_path.join("script-out");
    let _ = fs::remove_file(script_out.join("v31-upgrade-core.toml"));
    let _ = fs::remove_file(script_out.join("v31-upgrade-ecosystem.toml"));
    let _ = fs::remove_file(script_out.join("v31-upgrade-ctm.toml"));

    // The Solidity `initL2` hook on InteropCenter (triggered during the L2 upgrade tx)
    // rejects a zero ZK token asset ID, so we resolve a per-network value from the
    // built-in registry. TODO: source this from the ecosystem config once we have one.
    let l1_network = crate::types::L1Network::from_l1_rpc(&runner.rpc_url)?;
    let zk_token_asset_id = l1_network.zk_token_asset_id();

    let mut script_args = args.shared.forge_args.clone();
    // The Solidity function takes an EcosystemUpgradeParams struct, which is ABI-encoded as a tuple.
    script_args.add_arg(ForgeScriptArg::Sig {
        sig: "noGovernancePrepare((address,address,address,address,bool,bytes32,string,string,address,bytes32))".to_string(),
    });
    script_args.add_arg(ForgeScriptArg::RpcUrl {
        url: runner.rpc_url.clone(),
    });
    script_args.add_arg(ForgeScriptArg::Broadcast);
    script_args.add_arg(ForgeScriptArg::Ffi);
    script_args.add_arg(ForgeScriptArg::GasLimit {
        gas_limit: crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT,
    });
    // Struct fields are passed as a single tuple argument in parentheses.
    let params_tuple = format!(
        "({:#x},{:#x},{:#x},{:#x},{},{:#x},{},{},{:#x},{:#x})",
        bridgehub,
        ctm,
        bytecodes_supplier,
        rollup_da_manager,
        is_zk_sync_os,
        create2_salt,
        args.upgrade_input_path,
        args.upgrade_output_path,
        governance,
        zk_token_asset_id,
    );
    script_args.additional_args.push(params_tuple);

    let script = Forge::new(&contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(&sender);

    logger::step("Running ecosystem upgrade-prepare");
    logger::info(format!("RPC URL: {}", runner.rpc_url));

    runner
        .run(script)
        .context("Failed to execute forge script for upgrade-prepare")?;

    // Read TOML files written by the script; parse to JSON.
    let core_path = script_out.join("v31-upgrade-core.toml");
    let ecosystem_path = script_out.join("v31-upgrade-ecosystem.toml");
    let ctm_path = script_out.join("v31-upgrade-ctm.toml");

    let core_toml = fs::read_to_string(&core_path)
        .with_context(|| format!("Failed to read {}", core_path.display()))?;
    let ecosystem_toml = fs::read_to_string(&ecosystem_path)
        .with_context(|| format!("Failed to read {}", ecosystem_path.display()))?;
    let ctm_toml = fs::read_to_string(&ctm_path)
        .with_context(|| format!("Failed to read {}", ctm_path.display()))?;

    let core_json: Value = toml::from_str::<toml::Value>(&core_toml)
        .context("Failed to parse core TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;
    let ecosystem_json: Value = toml::from_str::<toml::Value>(&ecosystem_toml)
        .context("Failed to parse ecosystem TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;
    let ctm_json: Value = toml::from_str::<toml::Value>(&ctm_toml)
        .context("Failed to parse CTM TOML")
        .and_then(|v| serde_json::to_value(v).map_err(|e| anyhow::anyhow!("{}", e)))?;

    let run_json = runner
        .runs()
        .last()
        .map(|r| r.payload.clone())
        .unwrap_or_else(|| Value::Object(Default::default()));
    let out_payload = UpgradePrepareOutput {
        core: &core_json,
        ecosystem: &ecosystem_json,
        ctm: &ctm_json,
        run_json,
    };
    write_output_if_requested(
        "ecosystem.upgrade-prepare",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &out_payload,
    )
    .await?;

    // Copy the ecosystem TOML to the requested path if --governance-toml-out is set.
    if let Some(ref toml_out) = args.governance_toml_out {
        if let Some(parent) = toml_out.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&ecosystem_path, toml_out)
            .with_context(|| format!("Failed to copy ecosystem TOML to {}", toml_out.display()))?;
        logger::info(format!(
            "Governance TOML written to: {}",
            toml_out.display()
        ));
    }

    logger::success("Upgrade-prepare completed");
    if let Some(ref out_dir) = args.shared.out {
        logger::outro(format!(
            "Upgrade-prepare complete. Output written to: {}",
            out_dir.display()
        ));
    } else {
        logger::outro("Upgrade-prepare complete.");
    }
    Ok(())
}

fn resolve_script_output_path(contracts_path: &Path, output_path: &str) -> PathBuf {
    contracts_path.join(output_path.trim_start_matches('/'))
}

// ── upgrade-governance (stages 0 + 1 + 2 on one fork) ─────────────────────

/// Run governance stages 0, 1, and 2 on the same anvil fork. Forge's
/// broadcast log is appended once per stage, so the emitted Safe bundle
/// contains all three governance calls and signers approve them as one
/// atomic Safe transaction.
///
/// Stage 2 (unpause migrations) used to run separately after the chain
/// upgrade. Bundling it here is safe because the unpause call doesn't read
/// any v31-only state at simulation time, and from the multisig side a
/// single bundle is easier to coordinate than two.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct UpgradeGovernanceArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Path(s) to governance calls TOML(s) written by a prepare command via
    /// `--governance-toml-out`. Each TOML contains hex-encoded stage 0/1/2
    /// calldata. Pass `--governance-toml` once per TOML — typically once for
    /// `core-upgrade-prepare` and once per `ctm-upgrade-prepare` invocation.
    /// All stage-0 calls (across TOMLs in the order given) execute first, then
    /// all stage-1 calls, then all stage-2 calls. Each `governanceExecuteCalls`
    /// invocation lands in the same Safe bundle since the governance owner
    /// signs every stage.
    #[clap(long, num_args = 1..)]
    pub governance_toml: Vec<PathBuf>,
}

pub async fn run_upgrade_governance(args: UpgradeGovernanceArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?.bridgehub;
    let mut runner = ForgeRunner::new(&args.shared)?;

    // All three governance stages are signed by the Governance contract's
    // owner EOA.
    let sender = runner.prepare_governance_owner(bridgehub).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let governance_toml = Some(args.governance_toml.as_path());

    let mut governance_addr = Address::zero();
    for stage in 0..=2u8 {
        governance_addr = stage_governance_execute(
            &mut runner,
            &sender,
            &contracts_path,
            &args.shared.forge_args,
            governance_toml,
            bridgehub,
            stage,
        )
        .await
        .with_context(|| format!("governance stage {stage}"))?;
    }

    let out_payload = UpgradeGovernanceOutput {
        stages: "0,1,2",
        governance_address: format!("{:#x}", governance_addr),
    };
    write_output_if_requested(
        "ecosystem.upgrade-governance",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &out_payload,
    )
    .await?;

    if let Some(ref out_dir) = args.shared.out {
        logger::outro(format!(
            "Governance stages 0+1+2 complete. Output written to: {}",
            out_dir.display()
        ));
    } else {
        logger::outro("Governance stages 0+1+2 complete.");
    }
    Ok(())
}

fn resolve_l1_contracts_path(repo_root: &Path) -> anyhow::Result<PathBuf> {
    let direct = repo_root.join("l1-contracts");
    if direct.exists() {
        return Ok(direct);
    }

    let nested = repo_root.join("contracts").join("l1-contracts");
    if nested.exists() {
        return Ok(nested);
    }

    anyhow::bail!(
        "Could not resolve l1-contracts path under {} (tried {} and {})",
        repo_root.display(),
        direct.display(),
        nested.display()
    )
}

#[derive(Debug, Deserialize)]
struct GovernanceCalls {
    stage0_calls: String,
    stage1_calls: String,
    stage2_calls: String,
}

#[derive(Debug, Deserialize)]
struct EcosystemUpgradeOutput {
    governance_calls: GovernanceCalls,
}

/// Load the `stage{N}_calls` hex blob from the prepared ecosystem-upgrade
/// TOML (defaults to the canonical `script-out/...` location if no explicit
/// path is given).
fn read_governance_stage_calls(
    contracts_path: &Path,
    governance_toml: Option<&Path>,
    stage: u8,
) -> anyhow::Result<String> {
    let default_path = contracts_path.join("script-out/v31-upgrade-ecosystem.toml");
    let output_path = governance_toml.unwrap_or(&default_path);
    let toml_content = fs::read_to_string(output_path).with_context(|| {
        format!(
            "Failed to read ecosystem upgrade TOML: {}",
            output_path.display()
        )
    })?;
    let upgrade_output: EcosystemUpgradeOutput =
        toml::from_str(&toml_content).context("Failed to parse ecosystem upgrade TOML")?;
    let encoded_calls_hex = match stage {
        0 => upgrade_output.governance_calls.stage0_calls,
        1 => upgrade_output.governance_calls.stage1_calls,
        2 => upgrade_output.governance_calls.stage2_calls,
        _ => anyhow::bail!("Invalid stage: {}. Must be 0, 1, or 2", stage),
    };
    Ok(encoded_calls_hex)
}

/// Execute one `governanceExecuteCalls` invocation against an existing
/// `runner`. Called three times back-to-back from `run_upgrade_governance`
/// (once per stage 0/1/2) so the emitted Safe bundle contains all three.
async fn stage_governance_execute(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    contracts_path: &Path,
    forge_args: &crate::common::forge::ForgeScriptArgs,
    governance_toml: Option<&Path>,
    bridgehub: Address,
    stage: u8,
) -> anyhow::Result<Address> {
    let encoded_calls_hex = read_governance_stage_calls(contracts_path, governance_toml, stage)?;

    let governance_addr =
        crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
            .await
            .context("Failed to auto-resolve governance address from bridgehub")?;
    logger::info(format!(
        "Governance (auto-resolved): {:#x}",
        governance_addr
    ));

    let script_path = "deploy-scripts/AdminFunctions.s.sol";
    let mut script_args = forge_args.clone();
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

    let script = Forge::new(contracts_path)
        .script(Path::new(script_path), script_args)
        .with_wallet(sender);

    logger::step(format!("Running governance stage {}", stage));
    logger::info(format!("Governance address: {:#x}", governance_addr));
    logger::info(format!("RPC URL: {}", runner.rpc_url));

    runner.run(script).with_context(|| {
        format!(
            "Failed to execute forge script for governance stage {}",
            stage
        )
    })?;

    logger::success(format!("Governance stage {} completed", stage));
    Ok(governance_addr)
}
