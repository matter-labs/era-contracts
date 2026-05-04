//! Ecosystem-level v31 upgrade flow.
//!
//! Two top-level commands:
//!
//!   `upgrade-prepare-all` deploys new ecosystem contracts (deployer EOA signs)
//!                         by running `CoreUpgrade_v31` once + `CTMUpgrade_v31`
//!                         once per `--ctm-proxy` on a single anvil fork. Emits
//!                         per-script governance TOMLs.
//!   `upgrade-governance`  runs governance stages 0 + 1 + 2 on one anvil fork
//!                         and emits one Safe bundle (governance owner signs).
//!                         Accepts multiple `--governance-toml` args and orders
//!                         calls by stage across all of them.
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
use ethers::types::{Address, Bytes, H256};
use ethers::utils::hex;
use serde::{Deserialize, Serialize};

use crate::commands::ecosystem::v31_upgrade_full::V31UpgradeFull;
use crate::commands::ecosystem::v31_upgrade_inner::{V31PrepareInputs, V31UpgradeInner};
use crate::commands::output::write_output_if_requested;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::paths;
use crate::common::wallets::Wallet;
use crate::common::SharedRunArgs;
use crate::config::forge_interface::script_params::{
    ADMIN_FUNCTIONS_INVOCATION, CORE_UPGRADE_V31_SCRIPT_PATH, CTM_UPGRADE_V31_SCRIPT_PATH,
    UPGRADE_V31_CORE_OUTPUT_PATH, UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH,
};


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

#[derive(Serialize)]
struct UpgradeGovernanceOutput {
    stages: &'static str,
    governance_address: String,
}

pub async fn run_upgrade_governance(args: UpgradeGovernanceArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    // All three governance stages are signed by the Governance contract's
    // owner EOA.
    let sender = runner.prepare_governance_owner(bridgehub).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let toml_refs: Vec<&Path> = args.governance_toml.iter().map(|p| p.as_path()).collect();

    let governance_address = replay_governance_stages(
        &mut runner,
        &sender,
        &contracts_path,
        bridgehub,
        toml_refs.as_slice(),
    )
    .await?;

    let out_payload = UpgradeGovernanceOutput {
        stages: "0,1,2",
        governance_address: format!("{:#x}", governance_address),
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

// ── governance replay (used by `run_upgrade_governance`) ──────────────────

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

/// Replay stage 0/1/2 governance calls from one or more prepared TOMLs.
///
/// All stage-0 calls (across the TOMLs in the order given) execute first,
/// then all stage-1, then all stage-2. Each `governanceExecuteCalls`
/// invocation is signed by `sender` (the governance owner) so they merge
/// into one governance Safe bundle. Returns the resolved governance contract
/// address for diagnostics.
pub async fn replay_governance_stages(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    contracts_path: &Path,
    bridgehub: Address,
    governance_tomls: &[&Path],
) -> anyhow::Result<Address> {
    if governance_tomls.is_empty() {
        anyhow::bail!("at least one --governance-toml must be provided");
    }
    let mut governance_addr = Address::zero();
    for stage in 0..=2u8 {
        for toml_path in governance_tomls {
            governance_addr = stage_governance_execute(
                runner,
                sender,
                contracts_path,
                toml_path,
                bridgehub,
                stage,
            )
            .await
            .with_context(|| format!("governance stage {stage} ({})", toml_path.display()))?;
        }
    }
    Ok(governance_addr)
}

fn read_governance_stage_calls(governance_toml: &Path, stage: u8) -> anyhow::Result<String> {
    let toml_content = fs::read_to_string(governance_toml).with_context(|| {
        format!(
            "Failed to read governance TOML: {}",
            governance_toml.display()
        )
    })?;
    let upgrade_output: EcosystemUpgradeOutput =
        toml::from_str(&toml_content).context("Failed to parse governance TOML")?;
    Ok(match stage {
        0 => upgrade_output.governance_calls.stage0_calls,
        1 => upgrade_output.governance_calls.stage1_calls,
        2 => upgrade_output.governance_calls.stage2_calls,
        _ => anyhow::bail!("Invalid stage: {}. Must be 0, 1, or 2", stage),
    })
}

async fn stage_governance_execute(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    _contracts_path: &Path,
    governance_toml: &Path,
    bridgehub: Address,
    stage: u8,
) -> anyhow::Result<Address> {
    let encoded_calls_hex = read_governance_stage_calls(governance_toml, stage)?;

    let governance_addr =
        crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
            .await
            .context("Failed to auto-resolve governance address from bridgehub")?;
    logger::info(format!(
        "Governance (auto-resolved): {:#x}",
        governance_addr
    ));

    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            "governanceExecuteCalls",
            (
                Bytes::from(
                    hex::decode(encoded_calls_hex.trim_start_matches("0x"))
                        .context("invalid governance calls hex")?,
                ),
                governance_addr,
            ),
        )?
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(sender);

    logger::step(format!("Running governance stage {}", stage));
    logger::info(format!("Governance address: {:#x}", governance_addr));

    runner
        .run(script)
        .with_context(|| format!("Failed to execute forge script for governance stage {stage}"))?;

    logger::success(format!("Governance stage {} completed", stage));
    Ok(governance_addr)
}

pub fn resolve_l1_contracts_path(repo_root: &Path) -> anyhow::Result<PathBuf> {
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

// ── upgrade-prepare-all (split-flow orchestrator) ──────────────────────────

/// Unified split-flow prepare. Runs `CoreUpgrade_v31.noGovernancePrepare` once
/// and `CTMUpgrade_v31.noGovernancePrepare` once per `--ctm-proxy`, all on a
/// single anvil fork so deployer broadcasts merge into one Safe bundle. The
/// downstream `upgrade-governance` consumes the per-step TOMLs (passed as
/// `--governance-toml` once each).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct UpgradePrepareAllArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    #[clap(long)]
    pub deployer_address: Address,

    /// Target CTMs to upgrade. Pass once per CTM (e.g. ZKsyncOS CTM and EraVM
    /// CTM on stage). Each must already have at least one registered chain so
    /// rollup-DA-manager auto-resolution works.
    #[clap(long = "ctm-proxy", num_args = 1..)]
    pub ctm_proxies: Vec<Address>,

    #[clap(long)]
    pub create2_factory_salt: Option<H256>,

    #[clap(
        long,
        default_value = UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH,
        hide = true
    )]
    pub upgrade_input_path: String,

    /// Override the core-prepare output TOML path (relative to l1-contracts
    /// root). Defaults to the canonical `script-out/v31-upgrade-core.toml`.
    #[clap(long, default_value = UPGRADE_V31_CORE_OUTPUT_PATH, hide = true)]
    pub core_output_path: String,

    #[clap(long, default_value = CORE_UPGRADE_V31_SCRIPT_PATH, hide = true)]
    pub core_script_path: String,

    #[clap(long, default_value = CTM_UPGRADE_V31_SCRIPT_PATH, hide = true)]
    pub ctm_script_path: String,

    /// Override `isZKsyncOS`. Auto-resolved via `ctm.isZKsyncOS()` on v31+;
    /// pre-v31 ecosystems (where the getter doesn't exist yet) must pass
    /// this flag explicitly.
    #[clap(long)]
    pub is_zk_sync_os: Option<bool>,

    /// Override the bytecodes supplier address. Auto-resolved from CTM on
    /// v31+ ecosystems; pre-v31 callers must pass it explicitly.
    #[clap(long)]
    pub bytecodes_supplier_address: Option<Address>,

    /// Override the rollup DA manager address. Auto-resolved from a
    /// representative ZK chain on v31+ ecosystems; pre-v31 callers must
    /// pass it explicitly.
    #[clap(long)]
    pub rollup_da_manager_address: Option<Address>,
}

#[derive(Serialize)]
struct UpgradePrepareAllOutput {
    core_governance_toml: String,
    ctm_governance_tomls: Vec<CtmGovernanceTomlEntry>,
}

#[derive(Serialize)]
struct CtmGovernanceTomlEntry {
    ctm_proxy: String,
    governance_toml: String,
}

pub async fn run_upgrade_prepare_all(args: UpgradePrepareAllArgs) -> anyhow::Result<()> {
    if args.ctm_proxies.is_empty() {
        anyhow::bail!("at least one --ctm-proxy must be provided");
    }

    let bridgehub = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(args.deployer_address).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;

    let inputs = V31PrepareInputs {
        ctm_proxies: args.ctm_proxies.clone(),
        create2_factory_salt: args.create2_factory_salt,
        upgrade_input_path: args.upgrade_input_path.clone(),
        core_output_path: args.core_output_path.clone(),
        core_script_path: args.core_script_path.clone(),
        ctm_script_path: args.ctm_script_path.clone(),
        is_zk_sync_os_override: args.is_zk_sync_os,
        bytecodes_supplier_override: args.bytecodes_supplier_address,
        rollup_da_manager_override: args.rollup_da_manager_address,
    };
    let full = V31UpgradeFull::new(V31UpgradeInner::new(&contracts_path, bridgehub));
    let prepared = full.prepare(&mut runner, &deployer, &inputs).await?;

    // Copy each emitted TOML into `out_dir/governance-tomls/` so callers can
    // pass them back into `upgrade-governance` as `--governance-toml` args.
    let governance_tomls_dir = args.shared.out.clone().map(|d| d.join("governance-tomls"));
    let core_governance_toml = if let Some(dir) = &governance_tomls_dir {
        let dst = dir.join("v31-upgrade-core.toml");
        copy_governance_toml(&prepared.core_toml, &dst)?;
        dst
    } else {
        prepared.core_toml.clone()
    };
    let mut ctm_governance_tomls: Vec<CtmGovernanceTomlEntry> =
        Vec::with_capacity(prepared.ctm_tomls.len());
    for (ctm, src) in &prepared.ctm_tomls {
        let dst = if let Some(dir) = &governance_tomls_dir {
            let target = dir.join(format!("v31-upgrade-ctm-{ctm:#x}.toml"));
            copy_governance_toml(src, &target)?;
            target
        } else {
            src.clone()
        };
        ctm_governance_tomls.push(CtmGovernanceTomlEntry {
            ctm_proxy: format!("{ctm:#x}"),
            governance_toml: dst.display().to_string(),
        });
    }

    let out_payload = UpgradePrepareAllOutput {
        core_governance_toml: core_governance_toml.display().to_string(),
        ctm_governance_tomls,
    };
    write_output_if_requested(
        "ecosystem.upgrade-prepare-all",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &out_payload,
    )
    .await?;

    logger::success("upgrade-prepare-all completed");
    Ok(())
}

fn copy_governance_toml(src: &Path, dst: &Path) -> anyhow::Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)
        .with_context(|| format!("Failed to copy governance TOML to {}", dst.display()))?;
    logger::info(format!("Governance TOML written to: {}", dst.display()));
    Ok(())
}
