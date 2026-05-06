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
use crate::commands::ecosystem::v31_upgrade_inner::{CtmInputs, V31PrepareInputs, V31UpgradeInner};
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

pub async fn run_upgrade_governance(mut args: UpgradeGovernanceArgs) -> anyhow::Result<()> {
    // ── env preset auto-fills ────────────────────────────────────────
    let env_cfg = args.topology.env_config()?;
    if let Some(ref cfg) = env_cfg {
        let env_out_base = crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)?;
        // Default --out to upgrade-envs/.../<env>/protocol-ops/governance
        if args.shared.out.is_none() {
            args.shared.out = Some(env_out_base.join("governance"));
        }
        // Auto-discover the merged governance TOML from the prepare phase
        // output. `upgrade-prepare-all` emits a single `governance.toml`
        // containing core + per-CTM + PUH/Guardians stage-0 calls, so we no
        // longer need to merge multiple files at replay time.
        if args.governance_toml.is_empty() {
            let candidate = env_out_base.join("prepare").join("governance.toml");
            if candidate.is_file() {
                logger::info(format!(
                    "Auto-discovered governance TOML at {}",
                    candidate.display()
                ));
                args.governance_toml.push(candidate);
            }
        }
    }
    if args.governance_toml.is_empty() {
        anyhow::bail!(
            "no governance TOMLs supplied; pass --governance-toml or run with --env after a prepare phase"
        );
    }

    let bridgehub = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;

    // Pick the replay shape based on env config:
    //   - legacy Governance: signer = Ownable owner EOA, helper =
    //     `governanceExecuteCalls` (scheduleTransparent + execute path).
    //   - PUH: signer = the handler itself (anvil impersonates), helper =
    //     `governanceExecuteCallsDirect` (forwards each call).
    let governance_kind = env_cfg
        .as_ref()
        .map(|cfg| cfg.governance_kind())
        .unwrap_or_default();
    let governance_addr =
        crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub).await?;
    let sender = match governance_kind {
        crate::common::env_config::GovernanceKind::Legacy => {
            runner.prepare_governance_owner(bridgehub).await?
        }
        crate::common::env_config::GovernanceKind::Puh => {
            logger::info(format!(
                "Governance kind = puh; impersonating handler {:#x} directly (fork-only path)",
                governance_addr
            ));
            runner.prepare_sender(governance_addr).await?
        }
    };

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;
    let toml_refs: Vec<&Path> = args.governance_toml.iter().map(|p| p.as_path()).collect();

    let governance_address = replay_governance_stages(
        &mut runner,
        &sender,
        &contracts_path,
        bridgehub,
        toml_refs.as_slice(),
        governance_kind,
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
    governance_kind: crate::common::env_config::GovernanceKind,
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
                governance_kind,
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
    governance_kind: crate::common::env_config::GovernanceKind,
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

    let helper = match governance_kind {
        crate::common::env_config::GovernanceKind::Legacy => "governanceExecuteCalls",
        crate::common::env_config::GovernanceKind::Puh => "governanceExecuteCallsDirect",
    };
    let script = runner
        .with_script_call(
            &ADMIN_FUNCTIONS_INVOCATION,
            helper,
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

    /// Deployer EOA. Required for new envs; defaults to the
    /// `owner_address` field of the v31 upgrade input TOML when `--env` is set.
    #[clap(long)]
    pub deployer_address: Option<Address>,

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

    /// Path to a TOML file describing per-CTM inputs (proxy + optional
    /// overrides). Mutually exclusive with the legacy single-CTM flags
    /// (`--ctm-proxy`, `--is-zk-sync-os`, `--bytecodes-supplier-address`,
    /// `--rollup-da-manager-address`); use this when upgrading more than one
    /// CTM in a single fork (e.g. Era + Atlas/ZKsyncOS on stage/mainnet) or
    /// when the per-CTM overrides differ.
    ///
    /// Schema:
    /// ```toml
    /// [[ctm]]
    /// proxy = "0x..."
    /// is_zk_sync_os = false                  # optional
    /// bytecodes_supplier = "0x..."           # optional
    /// rollup_da_manager  = "0x..."           # optional
    /// ```
    #[clap(long, conflicts_with_all = [
        "ctm_proxies",
        "is_zk_sync_os",
        "bytecodes_supplier_address",
        "rollup_da_manager_address",
    ])]
    pub ctm_config: Option<PathBuf>,

    /// Override `isZKsyncOS`. Auto-resolved via `ctm.isZKsyncOS()` on v31+;
    /// pre-v31 ecosystems (where the getter doesn't exist yet) must pass
    /// this flag explicitly. Single-CTM legacy mode only — for multi-CTM,
    /// use `--ctm-config`.
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

#[derive(Debug, Deserialize)]
struct CtmConfigFile {
    #[serde(rename = "ctm", default)]
    ctms: Vec<CtmConfigEntry>,
    /// Override `isZKsyncOS` for the core prepare. The Core script is
    /// CTM-agnostic but its signature still takes the flag, so we need a
    /// value. Defaults to the value of the first CTM entry's `is_zk_sync_os`
    /// field if absent (and required if no per-CTM value is set either).
    #[serde(default)]
    core_is_zk_sync_os: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct CtmConfigEntry {
    proxy: Address,
    #[serde(default)]
    is_zk_sync_os: Option<bool>,
    #[serde(default)]
    bytecodes_supplier: Option<Address>,
    #[serde(default)]
    rollup_da_manager: Option<Address>,
}

#[derive(Serialize)]
struct UpgradePrepareAllOutput {
    core_governance_toml: String,
    ctm_governance_tomls: Vec<CtmGovernanceTomlEntry>,
    /// Merged stage 0/1/2 calls written to `<out>/prepare/governance.toml`,
    /// when `--out` is set. Downstream `upgrade-governance --env <env>` picks
    /// this up automatically.
    #[serde(skip_serializing_if = "Option::is_none")]
    merged_governance_toml: Option<String>,
    puh_proxy: String,
    new_puh_impl: String,
    new_guardians: String,
    puh_proxy_admin: String,
}

#[derive(Serialize)]
struct CtmGovernanceTomlEntry {
    ctm_proxy: String,
    governance_toml: String,
}

// ── ecosystem list-ctms ──────────────────────────────────────────────────

/// Enumerate every CTM registered on the supplied Bridgehub and print a
/// starter `--ctm-config` TOML. Used to discover the Atlas (ZKsyncOS) CTM
/// address on stage/testnet/mainnet without manual `cast call` chasing.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ListCtmsArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// L1 RPC URL to query.
    #[clap(long, default_value = "http://localhost:8545")]
    pub l1_rpc_url: String,

    /// Optional path to write the starter TOML to. When omitted, the TOML
    /// is printed to stdout.
    #[clap(long)]
    pub out: Option<PathBuf>,
}

pub async fn run_list_ctms(args: ListCtmsArgs) -> anyhow::Result<()> {
    let bridgehub = args.topology.resolve()?;
    let ctms = crate::common::l1_contracts::discover_all_ctms(&args.l1_rpc_url, bridgehub)
        .await
        .context("Failed to discover CTMs from bridgehub")?;
    if ctms.is_empty() {
        anyhow::bail!("Bridgehub {bridgehub:#x} has no registered chains, so no CTMs to list");
    }

    let mut out = String::new();
    out.push_str("# Generated by `protocol-ops ecosystem list-ctms`.\n");
    out.push_str(&format!("# Bridgehub: {bridgehub:#x}\n"));
    out.push_str(&format!("# L1 RPC:    {}\n", args.l1_rpc_url));
    out.push_str("#\n");
    out.push_str(
        "# `is_zk_sync_os`, `bytecodes_supplier`, `rollup_da_manager` are commented out\n\
         # so auto-resolution kicks in on v31+ ecosystems. Uncomment + fill them on pre-v31\n\
         # ecosystems where the on-chain getters don't exist yet.\n",
    );
    for (proxy, witness_chain) in &ctms {
        out.push_str("\n[[ctm]]\n");
        out.push_str(&format!(
            "# witness chain (any chain registered on this CTM): {witness_chain}\n"
        ));
        out.push_str(&format!("proxy = \"{proxy:#x}\"\n"));
        out.push_str("# is_zk_sync_os      = false\n");
        out.push_str("# bytecodes_supplier = \"0x...\"\n");
        out.push_str("# rollup_da_manager  = \"0x...\"\n");
    }

    if let Some(path) = &args.out {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, &out)
            .with_context(|| format!("Failed to write CTM config TOML to {}", path.display()))?;
        logger::success(format!("CTM config TOML written to: {}", path.display()));
    } else {
        // Print directly so a caller can `> ctm-config.toml` it.
        print!("{}", out);
    }
    Ok(())
}

pub async fn run_upgrade_prepare_all(mut args: UpgradePrepareAllArgs) -> anyhow::Result<()> {
    // ── env preset auto-fills ────────────────────────────────────────
    let env_cfg = args.topology.env_config()?;
    if let Some(ref cfg) = env_cfg {
        // Default --out to upgrade-envs/v0.31.0-interopB/output/<env>/protocol-ops/prepare/
        if args.shared.out.is_none() {
            args.shared.out =
                Some(crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)?.join("prepare"));
        }
        // Default --deployer-address to the env's owner_address.
        if args.deployer_address.is_none() {
            args.deployer_address = cfg.owner_address();
        }
    }
    let deployer_address = args
        .deployer_address
        .ok_or_else(|| anyhow::anyhow!("--deployer-address (or --env <name> with owner_address in the v31 input TOML) is required"))?;

    // ── CTM list resolution ─────────────────────────────────────────
    let (ctms, core_is_zk_sync_os_override) = if let Some(cfg_path) = &args.ctm_config {
        load_ctm_config(cfg_path)?
    } else if !args.ctm_proxies.is_empty() {
        // Legacy single-CTM mode: the global `--is-zk-sync-os` /
        // `--bytecodes-supplier-address` / `--rollup-da-manager-address`
        // overrides apply to every entry in `--ctm-proxy`.
        let ctms = args
            .ctm_proxies
            .iter()
            .map(|proxy| CtmInputs {
                proxy: *proxy,
                is_zk_sync_os: args.is_zk_sync_os,
                bytecodes_supplier: args.bytecodes_supplier_address,
                rollup_da_manager: args.rollup_da_manager_address,
            })
            .collect::<Vec<_>>();
        (ctms, args.is_zk_sync_os)
    } else if let Some(ref cfg) = env_cfg {
        let entries = cfg.ctms();
        if entries.is_empty() {
            anyhow::bail!(
                "permanent-values/{}.toml has no [[ctm_contracts.ctms]] entries — fill them in or pass --ctm-config / --ctm-proxy explicitly",
                cfg.env
            );
        }
        let zero = Address::zero();
        for (i, e) in entries.iter().enumerate() {
            if e.bytecodes_supplier == Some(zero) {
                anyhow::bail!(
                    "permanent-values/{}.toml [[ctm_contracts.ctms]][{}] proxy={:#x}: bytecodes_supplier still 0x0 (TODO marker) — fill it in",
                    cfg.env,
                    i,
                    e.proxy
                );
            }
        }
        let core_flavor = entries
            .iter()
            .find_map(|e| (e.is_zk_sync_os == Some(false)).then_some(false))
            .or_else(|| entries.first().and_then(|e| e.is_zk_sync_os));
        let ctms = entries
            .iter()
            .map(|e| CtmInputs {
                proxy: e.proxy,
                is_zk_sync_os: e.is_zk_sync_os,
                bytecodes_supplier: e.bytecodes_supplier,
                rollup_da_manager: e.rollup_da_manager,
            })
            .collect::<Vec<_>>();
        (ctms, core_flavor)
    } else {
        anyhow::bail!(
            "either --ctm-config, --ctm-proxy, or --env <name> (with [[ctm_contracts.ctms]] in permanent-values) must be provided"
        );
    };

    let bridgehub = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(deployer_address).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;

    let inputs = V31PrepareInputs {
        ctms,
        create2_factory_salt: args.create2_factory_salt,
        upgrade_input_path: args.upgrade_input_path.clone(),
        core_output_path: args.core_output_path.clone(),
        core_script_path: args.core_script_path.clone(),
        ctm_script_path: args.ctm_script_path.clone(),
        core_is_zk_sync_os_override,
    };
    let proxies: Vec<crate::common::env_config::OwnableProxyEntry> = env_cfg
        .as_ref()
        .map(|cfg| cfg.ownable_proxies().to_vec())
        .unwrap_or_default();
    let full = V31UpgradeFull::new(V31UpgradeInner::new(&contracts_path, bridgehub))
        .with_ownable_proxies(proxies);
    let prepared = full.prepare(&mut runner, &deployer, &inputs).await?;

    // Phase 1b on the same fork: redeploy ProtocolUpgradeHandler + Guardians
    // and capture the stage-0 governance calls that wire them into the live
    // PUH proxy. Only meaningful on PUH-governed envs (stage / mainnet) —
    // legacy-Governance envs (e.g. testnet's internal `0xc4fd…` bridgehub
    // owned by ZKsync `Governance.sol`) don't have a PUH to redeploy, so we
    // skip this step entirely and the merged governance.toml carries only
    // the core + per-CTM calls.
    let governance_kind = env_cfg
        .as_ref()
        .map(|c| c.governance_kind())
        .unwrap_or_default();
    let puh_outcome = if governance_kind
        == crate::common::env_config::GovernanceKind::Puh
    {
        Some(
            crate::commands::ecosystem::puh_guardians::deploy_puh_guardians(
                &mut runner,
                &deployer,
                &crate::commands::ecosystem::puh_guardians::PuhGuardiansInputs::from_env(
                    env_cfg.as_ref(),
                    bridgehub,
                ),
            )
            .await
            .context("PUH/Guardians redeploy step")?,
        )
    } else {
        logger::info(
            "Skipping PUH/Guardians redeploy (governance_kind != \"puh\" — env uses legacy Governance.sol)",
        );
        None
    };

    // Merge core + per-CTM governance calls + (when present) the in-memory
    // PUH/Guardians stage-0 calls into a single `<out>/prepare/governance.toml`.
    // The Solidity scripts each emit their own toml under `script-out/` (forge
    // requirement), but downstream we only care about one merged file.
    let merged_governance = if let Some(out_dir) = args.shared.out.clone() {
        let mut sources: Vec<PathBuf> = Vec::with_capacity(1 + prepared.ctm_tomls.len());
        sources.push(prepared.core_toml.clone());
        for (_ctm, src) in &prepared.ctm_tomls {
            sources.push(src.clone());
        }
        let merged_path = out_dir.join("governance.toml");
        let extra_stage0 = puh_outcome
            .as_ref()
            .map(|o| o.stage0_calls.as_slice())
            .unwrap_or(&[]);
        write_merged_governance_toml(&sources, extra_stage0, &merged_path)?;
        Some(merged_path)
    } else {
        None
    };

    let ctm_governance_tomls: Vec<CtmGovernanceTomlEntry> = prepared
        .ctm_tomls
        .iter()
        .map(|(ctm, src)| CtmGovernanceTomlEntry {
            ctm_proxy: format!("{ctm:#x}"),
            governance_toml: src.display().to_string(),
        })
        .collect();

    let out_payload = UpgradePrepareAllOutput {
        core_governance_toml: prepared.core_toml.display().to_string(),
        ctm_governance_tomls,
        merged_governance_toml: merged_governance
            .as_ref()
            .map(|p| p.display().to_string()),
        puh_proxy: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.puh_proxy))
            .unwrap_or_default(),
        new_puh_impl: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.new_puh_impl))
            .unwrap_or_default(),
        new_guardians: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.new_guardians))
            .unwrap_or_default(),
        puh_proxy_admin: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.proxy_admin))
            .unwrap_or_default(),
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

/// Read each per-script governance TOML and write a single merged TOML
/// containing all stage 0/1/2 calls in source-order (core first, then CTMs
/// in the order they were prepared). `extra_stage0` is appended to stage 0
/// after the file-sourced calls — used for the PUH/Guardians redeploy calls
/// emitted in-memory by [`puh_guardians::deploy_puh_guardians`].
fn write_merged_governance_toml(
    sources: &[PathBuf],
    extra_stage0: &[crate::common::governance_calls::GovernanceCall],
    dst: &Path,
) -> anyhow::Result<()> {
    use crate::common::governance_calls::{empty_calls_hex, encode_calls, merge_call_array_hex};
    use ethers::utils::hex;

    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut stage0: Vec<String> = Vec::new();
    let mut stage1: Vec<String> = Vec::new();
    let mut stage2: Vec<String> = Vec::new();
    for src in sources {
        let raw = fs::read_to_string(src).with_context(|| format!("read {}", src.display()))?;
        let parsed: EcosystemUpgradeOutput =
            toml::from_str(&raw).with_context(|| format!("parse {}", src.display()))?;
        stage0.push(parsed.governance_calls.stage0_calls);
        stage1.push(parsed.governance_calls.stage1_calls);
        stage2.push(parsed.governance_calls.stage2_calls);
    }
    let extra_stage0_hex = if extra_stage0.is_empty() {
        None
    } else {
        Some(format!("0x{}", hex::encode(encode_calls(extra_stage0))))
    };
    if let Some(ref h) = extra_stage0_hex {
        stage0.push(h.clone());
    }
    let s0 = if stage0.is_empty() {
        empty_calls_hex()
    } else {
        merge_call_array_hex(&stage0.iter().map(String::as_str).collect::<Vec<_>>())?
    };
    let s1 = if stage1.is_empty() {
        empty_calls_hex()
    } else {
        merge_call_array_hex(&stage1.iter().map(String::as_str).collect::<Vec<_>>())?
    };
    let s2 = if stage2.is_empty() {
        empty_calls_hex()
    } else {
        merge_call_array_hex(&stage2.iter().map(String::as_str).collect::<Vec<_>>())?
    };
    let body = format!(
        "# Auto-generated by `protocol-ops ecosystem upgrade-prepare-all`.\n\
         # Merged governance calls from {} per-script TOML(s).\n\
         \n\
         [governance_calls]\n\
         stage0_calls = \"{s0}\"\n\
         stage1_calls = \"{s1}\"\n\
         stage2_calls = \"{s2}\"\n",
        sources.len()
    );
    fs::write(dst, body)
        .with_context(|| format!("Failed to write merged governance TOML: {}", dst.display()))?;
    logger::info(format!("Merged governance TOML written to: {}", dst.display()));
    Ok(())
}

/// Read the multi-CTM config TOML and return per-CTM inputs + the
/// `core_is_zk_sync_os` value to pass to the Core script. If the TOML doesn't
/// set `core_is_zk_sync_os`, fall back to the first CTM entry's `is_zk_sync_os`
/// (and require that one to be set in that case — Core needs *some* value).
fn load_ctm_config(path: &Path) -> anyhow::Result<(Vec<CtmInputs>, Option<bool>)> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read CTM config TOML: {}", path.display()))?;
    let parsed: CtmConfigFile = toml::from_str(&content)
        .with_context(|| format!("Failed to parse CTM config TOML: {}", path.display()))?;

    if parsed.ctms.is_empty() {
        anyhow::bail!(
            "CTM config TOML has no `[[ctm]]` entries: {}",
            path.display()
        );
    }

    let core_is_zk_sync_os = parsed
        .core_is_zk_sync_os
        .or_else(|| parsed.ctms.first().and_then(|c| c.is_zk_sync_os));

    let ctms: Vec<CtmInputs> = parsed
        .ctms
        .into_iter()
        .map(|e| CtmInputs {
            proxy: e.proxy,
            is_zk_sync_os: e.is_zk_sync_os,
            bytecodes_supplier: e.bytecodes_supplier,
            rollup_da_manager: e.rollup_da_manager,
        })
        .collect();

    Ok((ctms, core_is_zk_sync_os))
}
