//! Ecosystem-level v31 upgrade flow.
//!
//! Two top-level commands:
//!
//!   `upgrade-prepare-all` deploys new ecosystem contracts (deployer EOA signs)
//!                         by running `CoreUpgrade_v31` once + `CTMUpgrade_v31`
//!                         once per `--ctm-proxy` on a single anvil fork, then
//!                         executes operational CTM-admin calls such as
//!                         ServerNotifier ProxyAdmin upgrades. Emits per-script
//!                         governance TOMLs.
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

const SKIP_PUH_ENV_VAR: &str = "SKIP_PUH";

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

    /// Path(s) to TOML(s) carrying a top-level `[governance_calls]` table with
    /// hex-encoded `stage0_calls` / `stage1_calls` / `stage2_calls`. Typically
    /// the single merged ecosystem TOML written by `upgrade-prepare-all`
    /// (`<out>/ecosystem.toml`); legacy per-script TOMLs (one core + one per
    /// CTM) also work and may be passed multiple times. All stage-0 calls
    /// (across TOMLs in the order given) execute first, then all stage-1
    /// calls, then all stage-2 calls. Each `governanceExecuteCalls` invocation
    /// lands in the same Safe bundle since the governance owner signs every
    /// stage.
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
        // Auto-discover the merged ecosystem TOML from the prepare phase
        // output. `upgrade-prepare-all` writes a single `ecosystem.toml`
        // directly at `<env-out>/ecosystem.toml` (canonical tracked path)
        // whose top-level `[governance_calls]` table carries the merged
        // stage 0/1/2 calls (core + per-CTM + PUH/Guardians stage-0), so
        // we no longer need to merge multiple files at replay time.
        if args.governance_toml.is_empty() {
            let candidate = env_out_base.join("ecosystem.toml");
            if candidate.is_file() {
                logger::info(format!(
                    "Auto-discovered ecosystem TOML at {}",
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
/// single anvil fork so deployer and operational admin broadcasts emit as one
/// prepare bundle set. The downstream `upgrade-governance` consumes the
/// per-step TOMLs (passed as `--governance-toml` once each).
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct UpgradePrepareAllArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Deployer EOA — the address whose private key you'll later use to
    /// sign the deployer bundle via `ecosystem upgrade-broadcast --key`. The
    /// prepare phase doesn't need the key itself (it's all simulation), but
    /// it does need the address so the emitted Safe bundle's filename / the
    /// in-bundle tx `from` field match the eventual broadcaster. Always
    /// required: we intentionally do not fall back to the env's
    /// `owner_address` because on stage/mainnet that's the
    /// ProtocolUpgradeHandler contract, which isn't a signable EOA.
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
    /// Merged ecosystem TOML written to `<env-out>/ecosystem.toml`, when
    /// `--out` is set. Contains top-level `[governance_calls]` (merged stage
    /// 0/1/2 hex), `[core]` (the CTM-agnostic core prepare output), and one
    /// `[ctms.<flavor>]` table per CTM (`era` or `zksync_os`, keyed off
    /// `is_zk_sync_os`) carrying the per-CTM diamond cut + contracts config.
    /// Downstream `upgrade-governance --env <env>` and `verify-upgrade` both
    /// consume this single file.
    #[serde(skip_serializing_if = "Option::is_none")]
    merged_ecosystem_toml: Option<String>,
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
            args.shared.out = Some(
                crate::common::env_config::default_protocol_ops_out_dir(&cfg.env)?.join("prepare"),
            );
        }
        // Note: we intentionally do *not* default `--deployer-address` from
        // the env's `owner_address`. On stage / mainnet the env's
        // `owner_address` is the ProtocolUpgradeHandler (a contract owned by
        // governance) — it's the *semantic* owner of the ecosystem, not the
        // EOA that signs deployment txs. Using it as the broadcaster only
        // works on a fork via `anvil_impersonateAccount`; on a real chain
        // nobody can sign as that contract. The caller must pass
        // `--deployer-address <real-EOA>` (or derive it from the broadcast
        // signer's private key — see `regen-and-verify-stage.sh` for an
        // example using `cast wallet address`).
        // Default --upgrade-input-path to upgrade-envs/v0.31.0-interopB/<env>.toml
        // when running with `--env`. The CLI default is `local.toml` (for
        // local-anvil fixtures). On stage / mainnet / testnet the per-env
        // file carries env-specific knobs the upgrade scripts rely on —
        // most importantly `message_root_stage_sepolia_variant = true` for
        // stage, which switches `CoreUpgrade_v31._messageRootContractName()`
        // to the variant that skips chain 270's still-on-GW-123 settlement
        // check. Without this override, stage's L1MessageRoot upgrade reverts
        // during stage-1 governance with `NotAllChainsOnL1`. Only override
        // when the caller hasn't explicitly passed `--upgrade-input-path`.
        if args.upgrade_input_path == UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH {
            let per_env_rel = format!("/upgrade-envs/v0.31.0-interopB/{}.toml", cfg.env);
            let per_env_abs = paths::contracts_root()
                .join("l1-contracts")
                .join(per_env_rel.trim_start_matches('/'));
            if per_env_abs.exists() {
                logger::info(format!("Using per-env upgrade input: {}", per_env_rel));
                args.upgrade_input_path = per_env_rel;
            } else {
                logger::info(format!(
                    "Per-env upgrade input not found at {} — falling back to default {}",
                    per_env_abs.display(),
                    UPGRADE_V31_INTEROP_LOCAL_INPUT_PATH
                ));
            }
        }
    }
    // Auto-fill the CREATE2 salt from the per-version upgrade input
    // (`upgrade-envs/v0.31.0-interopB/<env>.toml [contracts]
    // create2_factory_salt`). Recording the salt in version control makes
    // re-prepares reproducible (same addresses every run regardless of who
    // runs it), so deployer-bundle broadcasts can land at addresses that
    // match a later re-prepare's references. Caller can still override
    // with explicit `--create2-factory-salt`.
    if args.create2_factory_salt.is_none() {
        if let Some(cfg) = env_cfg.as_ref() {
            if let Some(salt) = cfg.v31_create2_factory_salt()? {
                logger::info(format!(
                    "Using create2_factory_salt from {}: {salt:#x}",
                    cfg.v31_input_path.display(),
                ));
                args.create2_factory_salt = Some(salt);
            }
        }
    }

    // Plumb the per-regen legacy-Gov ceremony salt down to every forge
    // script the prepare flow spawns. `Utils.executeCalls` / `executeUpgrade`
    // read this via `vm.envOr("LEGACY_GOV_SALT", bytes32(0))`. Child
    // processes inherit env vars from this process, so a single `set_var`
    // here covers every script in the pipeline. See
    // `contracts/.claude/skills/regenerate-v31-stage-calldata/SKILL.md`
    // ("Core principle") for why a per-regen salt is required.
    if let Some(cfg) = env_cfg.as_ref() {
        if let Some(salt) = cfg.v31_legacy_gov_salt()? {
            logger::info(format!(
                "Using legacy_gov_salt from {}: {salt:#x}",
                cfg.v31_input_path.display(),
            ));
            std::env::set_var("LEGACY_GOV_SALT", format!("{salt:#x}"));
        }
    }

    let deployer_address = args.deployer_address.ok_or_else(|| {
        anyhow::anyhow!(
            "--deployer-address is required. Pass an EOA whose private key you control \
             (e.g. derive it with `cast wallet address --private-key $(cat ~/.test_pk)`); \
             we no longer auto-fall back to the env's `owner_address` because that is the \
             ecosystem's governance contract on stage/mainnet — not a signable EOA."
        )
    })?;

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
        let ctms = entries
            .iter()
            .map(|e| CtmInputs {
                proxy: e.proxy,
                is_zk_sync_os: e.is_zk_sync_os,
                bytecodes_supplier: e.bytecodes_supplier,
                rollup_da_manager: e.rollup_da_manager,
            })
            .collect::<Vec<_>>();
        (ctms, infer_core_is_zk_sync_os(entries))
    } else {
        anyhow::bail!(
            "either --ctm-config, --ctm-proxy, or --env <name> (with [[ctm_contracts.ctms]] in permanent-values) must be provided"
        );
    };

    let bridgehub = args.topology.resolve()?;
    let zk_token_asset_id = match env_cfg.as_ref() {
        Some(cfg) => cfg.zk_token_asset_id().ok_or_else(|| {
            anyhow::anyhow!(
                "permanent-values/{}.toml is missing top-level `zk_token_asset_id`; \
                 named envs must define it explicitly because there is no canonical network-wide value",
                cfg.env
            )
        })?,
        None => crate::types::L1Network::from_l1_rpc(&args.shared.l1_rpc_url)?
            .zk_token_asset_id()?,
    };
    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(deployer_address).await?;

    let contracts_path = resolve_l1_contracts_path(&paths::contracts_root())?;

    let create2_factory_salt_per_ctm = match env_cfg.as_ref() {
        Some(cfg) => {
            let map = cfg.v31_create2_factory_salt_per_ctm()?;
            if map.is_empty() {
                None
            } else {
                logger::info(format!(
                    "Using {} per-CTM create2 salts from {}",
                    map.len(),
                    cfg.v31_input_path.display()
                ));
                Some(map)
            }
        }
        None => None,
    };

    let inputs = V31PrepareInputs {
        ctms,
        create2_factory_salt: args.create2_factory_salt,
        create2_factory_salt_per_ctm,
        upgrade_input_path: args.upgrade_input_path.clone(),
        core_output_path: args.core_output_path.clone(),
        core_script_path: args.core_script_path.clone(),
        ctm_script_path: args.ctm_script_path.clone(),
        core_is_zk_sync_os_override,
        zk_token_asset_id,
    };
    let proxies: Vec<crate::common::env_config::OwnableProxyEntry> = env_cfg
        .as_ref()
        .map(|cfg| cfg.ownable_proxies().to_vec())
        .unwrap_or_default();
    let new_gateway_cfg = env_cfg.as_ref().and_then(|cfg| cfg.new_gateway().cloned());
    let full = V31UpgradeFull::new(V31UpgradeInner::new(&contracts_path, bridgehub))
        .with_ownable_proxies(proxies)
        .with_new_gateway(new_gateway_cfg);
    let prepared = full.prepare(&mut runner, &deployer, &inputs).await?;

    // `ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps` wrote one
    // `acceptOwnership()` Call per Ownable2Step CTM whose pendingOwner is PUH.
    // Those calls must execute as PUH via the governance ceremony — folded
    // into stage 0 below, alongside the PUH/Guardians redeploy calls.
    let pre_gov_accept_calls = read_pre_governance_accept_ownership_calls(&contracts_path)?;

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
    // TEMPORARY -- do remove
    let is_puh_governed = governance_kind == crate::common::env_config::GovernanceKind::Puh;
    let skip_puh = std::env::var_os(SKIP_PUH_ENV_VAR).is_some();
    let puh_outcome = if is_puh_governed && !skip_puh {
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
        if is_puh_governed {
            logger::info(format!(
                "Skipping PUH/Guardians redeploy ({SKIP_PUH_ENV_VAR} is set)"
            ));
        } else {
            logger::info(
                "Skipping PUH/Guardians redeploy (governance_kind != \"puh\" — env uses legacy Governance.sol)",
            );
        }
        None
    };

    // Merge core + per-CTM governance calls + (when present) the in-memory
    // PUH/Guardians stage-0 calls + (when present) the new-Gateway bring-up
    // bundle into a single `<env-out>/ecosystem.toml`. The Solidity
    // scripts each emit their own toml under `script-out/` (forge
    // requirement), but downstream (PUVT + governance replay) only consumes
    // the merged file.
    // Write the merged TOML straight to the canonical tracked path
    // (`<env-out>/ecosystem.toml`) — that's the file reviewers diff and the
    // path every downstream consumer (PUVT, simulator emitter, fork tests)
    // reads from. The `prepare/` subtree under `--out` keeps the per-bundle
    // intermediates (safe.json + manifest.json + executed.json) which stay
    // untracked.
    let merged_ecosystem = if let Some(out_dir) = args.shared.out.clone() {
        let canonical_dir = out_dir.parent().ok_or_else(|| {
            anyhow::anyhow!(
                "--out ({}) has no parent directory; cannot derive canonical ecosystem.toml path",
                out_dir.display()
            )
        })?;
        let merged_path = canonical_dir.join("ecosystem.toml");
        let mut extra_stage0: Vec<crate::common::governance_calls::GovernanceCall> = puh_outcome
            .as_ref()
            .map(|o| o.stage0_calls.clone())
            .unwrap_or_default();
        extra_stage0.extend(pre_gov_accept_calls.iter().cloned());
        write_merged_ecosystem_toml(
            &prepared.core_toml,
            &prepared.ctm_tomls,
            &extra_stage0,
            prepared.new_gateway_toml.as_deref(),
            inputs.zk_token_asset_id,
            &merged_path,
        )?;
        logger::info(format!(
            "Wrote merged ecosystem.toml → {}",
            merged_path.display()
        ));
        let extra_verification_logs_path = canonical_dir.join("extra-verification-logs.txt");
        runner.write_extra_verification_logs(&extra_verification_logs_path)?;
        logger::info(format!(
            "Wrote extra verification logs → {}",
            extra_verification_logs_path.display()
        ));
        Some(merged_path)
    } else {
        None
    };

    let ctm_governance_tomls: Vec<CtmGovernanceTomlEntry> = prepared
        .ctm_tomls
        .iter()
        .map(|entry| CtmGovernanceTomlEntry {
            ctm_proxy: format!("{:#x}", entry.proxy),
            governance_toml: entry.toml.display().to_string(),
        })
        .collect();

    let out_payload = UpgradePrepareAllOutput {
        core_governance_toml: prepared.core_toml.display().to_string(),
        ctm_governance_tomls,
        merged_ecosystem_toml: merged_ecosystem.as_ref().map(|p| p.display().to_string()),
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

/// Pick the `is_zk_sync_os` flavor the Core script will deploy under when
/// running against a multi-CTM ecosystem (Era + Atlas). Era wins if any entry
/// declares `is_zk_sync_os = false` — its system contracts are the strict
/// subset, so a Core deploy targeting Era is also valid for Atlas. If no entry
/// pins the flavor, fall back to the first entry's hint.
fn infer_core_is_zk_sync_os(entries: &[crate::common::env_config::CtmEntry]) -> Option<bool> {
    entries
        .iter()
        .find_map(|e| (e.is_zk_sync_os == Some(false)).then_some(false))
        .or_else(|| entries.first().and_then(|e| e.is_zk_sync_os))
}

/// Read each per-script governance TOML and write a single merged TOML
/// containing all stage 0/1/2 calls in source-order (core first, then CTMs
/// in the order they were prepared, then the optional new-Gateway bundle
/// appended to stage 2). `extra_stage0` is appended to stage 0 after the
/// file-sourced calls — used for the PUH/Guardians redeploy calls emitted
/// in-memory by [`puh_guardians::deploy_puh_guardians`].
/// Merge the core + per-CTM prepare TOMLs (plus optional in-memory PUH
/// stage-0 calls and an optional `GatewayVotePreparation` bundle for the
/// new gateway) into a single ecosystem TOML at `dst`. Shape:
///
/// ```toml
/// [governance_calls]              # merged stage 0/1/2 hex across all sources
/// stage0_calls = "0x..."
/// stage1_calls = "0x..."
/// stage2_calls = "0x..."
///
/// [core]                          # whole core TOML minus its [governance_calls]
/// ...
///
/// [ctms.era]                      # whole CTM TOML minus its [governance_calls];
/// ...                             # key is "era" if !is_zk_sync_os else "zksync_os".
/// [ctms.zksync_os]                # second CTM, when present.
/// ...
///
/// [new_gateway]                   # only when present: GatewayVotePreparation
/// ...                             # output minus governance_calls_to_execute.
/// ```
fn write_merged_ecosystem_toml(
    core_toml: &Path,
    ctm_entries: &[crate::commands::ecosystem::v31_upgrade_inner::CtmPrepareEntry],
    extra_stage0: &[crate::common::governance_calls::GovernanceCall],
    new_gateway_toml: Option<&Path>,
    zk_token_asset_id: ethers::types::H256,
    dst: &Path,
) -> anyhow::Result<()> {
    use crate::common::governance_calls::{
        empty_calls_hex, encode_calls, merge_call_array_hex, GovernanceCall,
    };
    use ethers::types::U256;
    use ethers::utils::hex;
    use toml::value::{Table, Value};

    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }

    // Read each source as a generic TOML table; pop [governance_calls] out so
    // it can be merged at the top level, leaving the rest to embed verbatim.
    fn load_and_split(path: &Path) -> anyhow::Result<(Table, GovernanceCalls)> {
        let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let mut value: Table =
            toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
        let gov = value
            .remove("governance_calls")
            .with_context(|| format!("missing [governance_calls] in {}", path.display()))?;
        let gov: GovernanceCalls = gov
            .try_into()
            .with_context(|| format!("invalid [governance_calls] in {}", path.display()))?;
        Ok((value, gov))
    }

    let (mut core_body, core_gov) = load_and_split(core_toml)?;
    let misc_body = match core_body.remove("misc") {
        Some(Value::Table(table)) => Some(table),
        Some(other) => anyhow::bail!(
            "[misc] in {} must be a table (got {})",
            core_toml.display(),
            other.type_str()
        ),
        None => None,
    };

    let mut ctms_table: Table = Table::new();
    let mut stage0: Vec<String> = vec![core_gov.stage0_calls];
    let mut stage1: Vec<String> = vec![core_gov.stage1_calls];
    let mut stage2: Vec<String> = vec![core_gov.stage2_calls];

    for entry in ctm_entries {
        let (body, gov) = load_and_split(&entry.toml)?;
        let label = if entry.is_zk_sync_os {
            "zksync_os"
        } else {
            "era"
        };
        if ctms_table.contains_key(label) {
            anyhow::bail!(
                "duplicate CTM flavor `{label}`: two CTMs cannot share the same `is_zk_sync_os` value in one upgrade"
            );
        }
        ctms_table.insert(label.to_string(), Value::Table(body));
        stage0.push(gov.stage0_calls);
        stage1.push(gov.stage1_calls);
        stage2.push(gov.stage2_calls);
    }

    if !extra_stage0.is_empty() {
        stage0.push(format!("0x{}", hex::encode(encode_calls(extra_stage0))));
    }

    // `GatewayVotePreparation` writes a flat TOML whose `governance_calls_to_execute`
    // field is an abi-encoded `Call[]`. Pop that into the stage-2 chunks, keep
    // the rest (per-contract addresses + diamond cut data) under a top-level
    // `[new_gateway]` block so reviewers can still audit the deployed addresses.
    //
    // Before appending the GW bundle, *prepend* a call to
    // `L1AssetTracker.registerLegacyToken(zkTokenAssetId)`. The GW bundle
    // contains L1→L2 priority txs that charge the GW's base token (ZK on
    // ZKsyncOS chains); after stage 1 swaps the NTV to v31, those base-token
    // burns route through `L1AssetTracker.handleChainBalanceIncreaseOnL1`
    // which calls `_requireRegistered`. The registration normally happens in
    // stage3 (post-governance), so without this prepend the GW priority txs
    // revert with `AssetIdNotRegistered`. The injected call is idempotent on
    // the assetId (its `isAssetRegistered` guard short-circuits a second
    // call), so stage3 still succeeds when it walks the same assetId later.
    let new_gateway_body: Option<Table> = if let Some(path) = new_gateway_toml {
        let asset_tracker = read_asset_tracker_proxy_from_core(core_toml)?;
        let selector = &ethers::utils::id("registerLegacyToken(bytes32)")[..4];
        let mut data = Vec::with_capacity(36);
        data.extend_from_slice(selector);
        data.extend_from_slice(zk_token_asset_id.as_bytes());
        let prefix = vec![GovernanceCall {
            target: asset_tracker,
            value: U256::zero(),
            data,
        }];
        stage2.push(format!("0x{}", hex::encode(encode_calls(&prefix))));

        let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let mut value: Table =
            toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
        let gov_hex = value
            .remove("governance_calls_to_execute")
            .with_context(|| {
                format!("missing governance_calls_to_execute in {}", path.display())
            })?;
        let gov_hex = match gov_hex {
            Value::String(s) => s,
            other => anyhow::bail!(
                "governance_calls_to_execute in {} is not a string (got {})",
                path.display(),
                other.type_str()
            ),
        };
        stage2.push(gov_hex);
        // Leave `ecosystem_admin_calls_to_execute` (if present) untouched in
        // the [new_gateway] body. For the existing-ServerNotifier case our
        // patched `GatewayVotePreparation.s.sol` emits a zero-length
        // `Call[]` there; the in-place impl upgrade is emitted by the per-CTM
        // `DefaultCTMUpgrade.prepareUpgradeServerNotifierCall`. Initial-GW
        // setups still get the same non-empty calls — downstream routing for
        // those scenarios isn't wired here yet.
        Some(value)
    } else {
        None
    };

    let merge = |chunks: &[String]| -> anyhow::Result<String> {
        if chunks.is_empty() {
            Ok(empty_calls_hex())
        } else {
            merge_call_array_hex(&chunks.iter().map(String::as_str).collect::<Vec<_>>())
        }
    };
    let s0 = merge(&stage0)?;
    let s1 = merge(&stage1)?;
    let s2 = merge(&stage2)?;

    let mut governance_calls_table = Table::new();
    governance_calls_table.insert("stage0_calls".into(), Value::String(s0));
    governance_calls_table.insert("stage1_calls".into(), Value::String(s1));
    governance_calls_table.insert("stage2_calls".into(), Value::String(s2));

    // Build the document with [governance_calls] first, then [core], then
    // [ctms.*], optional [new_gateway], and [misc] last. `toml::to_string`
    // orders keys as inserted.
    let mut doc = Table::new();
    doc.insert(
        "governance_calls".into(),
        Value::Table(governance_calls_table),
    );
    doc.insert("core".into(), Value::Table(core_body));
    doc.insert("ctms".into(), Value::Table(ctms_table));
    if let Some(body) = new_gateway_body {
        doc.insert("new_gateway".into(), Value::Table(body));
    }
    if let Some(body) = misc_body {
        doc.insert("misc".into(), Value::Table(body));
    }

    let new_gateway_count = if new_gateway_toml.is_some() { 1 } else { 0 };
    let body = format!(
        "# Auto-generated by `protocol-ops ecosystem upgrade-prepare-all`.\n\
         # Merged ecosystem upgrade artifact: top-level [governance_calls] holds\n\
         # the combined stage 0/1/2 hex from {} prepare TOML(s); [core] mirrors the\n\
         # core prepare output (minus its own [governance_calls]); [ctms.<flavor>]\n\
         # mirrors each per-CTM prepare output (one section per `is_zk_sync_os`\n\
         # value) for downstream verification. [misc] carries shared metadata used\n\
         # by verification. When [new_gateway] is present, it\n\
         # mirrors GatewayVotePreparation's output (deployed GW CTM addresses +\n\
         # diamond cut data) — its `governance_calls_to_execute` has already been\n\
         # folded into stage 2 above.\n\n{}",
        1 + ctm_entries.len() + new_gateway_count,
        toml::to_string(&doc).context("serialize merged ecosystem TOML")?
    );
    fs::write(dst, body)
        .with_context(|| format!("Failed to write merged ecosystem TOML: {}", dst.display()))?;
    logger::info(format!(
        "Merged ecosystem TOML written to: {}",
        dst.display()
    ));
    Ok(())
}

/// Walk every safe.json bundle under `prepare_dir` and rewrite each
/// `transferOwnership(address)` tx whose `to` is in `targets` so the address
/// argument points at `new_pending_owner` instead of whatever ChainAdmin
/// Read the `acceptOwnership()` Call list written by
/// `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
/// (in `<l1-contracts>/script-out/pre-governance-accept-ownerships.toml`).
/// Returns an empty vector when the file doesn't exist (e.g. a prior regen
/// without this step) — the merge step then has nothing to fold and the
/// behavior matches the pre-refactor "no extra stage-0 calls" path.
pub(super) fn read_pre_governance_accept_ownership_calls(
    contracts_path: &Path,
) -> anyhow::Result<Vec<crate::common::governance_calls::GovernanceCall>> {
    let path = contracts_path
        .join("script-out")
        .join("pre-governance-accept-ownerships.toml");
    if !path.exists() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let parsed: toml::Table =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    // foundry's `vm.serializeBytes(objectKey, valueKey, value)` + `vm.writeToml(_, path)`
    // emits `valueKey = "0x..."` at the root of the TOML — the `objectKey`
    // is just the serialization identifier, not a nested table. So the
    // file's top-level key is `calls`, not `pre_governance_accept_ownerships.calls`.
    let hex_str = parsed
        .get("calls")
        .and_then(|v| v.as_str())
        .with_context(|| format!("missing calls in {}", path.display()))?;
    crate::common::governance_calls::decode_calls(hex_str).with_context(|| {
        format!(
            "decode pre_governance_accept_ownerships.calls from {}",
            path.display()
        )
    })
}

/// `GatewayVotePreparation` emitted. After phase 2 broadcasts those bundles
/// the new pendingOwner becomes `new_pending_owner`; stage-2 governance's
/// `acceptOwnership()` (also routed to PUH by the merge step) then succeeds.
///
/// Pull `asset_tracker_proxy_addr` off the core prepare TOML. Same data
/// `prepare_new_gateway::read_asset_tracker_proxy` reads — duplicated here
/// because the merge step also needs it for the stage-2 prefix call, and
/// keeping it crate-local avoids pulling the gateway-prepare module into
/// the merge module.
fn read_asset_tracker_proxy_from_core(core_toml: &Path) -> anyhow::Result<Address> {
    #[derive(serde::Deserialize)]
    struct Top {
        asset_tracker_proxy_addr: String,
    }
    let raw =
        fs::read_to_string(core_toml).with_context(|| format!("read {}", core_toml.display()))?;
    let top: Top =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    top.asset_tracker_proxy_addr.parse().with_context(|| {
        format!(
            "asset_tracker_proxy_addr in {} is not a valid address: {}",
            core_toml.display(),
            top.asset_tracker_proxy_addr,
        )
    })
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
