//! Ecosystem-level upgrade flow.
//!
//! Two top-level commands:
//!
//!   `upgrade-prepare-all` deploys new ecosystem contracts (deployer EOA signs)
//!                         by running the release's `CoreUpgrade_v<N>` once + `CTMUpgrade_v<N>`
//!                         once for the target `--ctm-proxy` on a single anvil fork, then
//!                         executes the CTM-admin calls the CTM prepare emits (the
//!                         registry bootstrap's ServerNotifier handover; none on a
//!                         recurring upgrade). Emits per-script governance TOMLs.
//!   `upgrade-governance`  replays the package's one governance bundle
//!                         (`[governance_calls] calls`) on an anvil fork and emits
//!                         one Safe bundle (governance owner signs). Accepts
//!                         multiple `--governance-toml` args and replays their
//!                         bundles in the order given.

use std::fs;
use std::path::{Path, PathBuf};

use alloy::hex;
use alloy::primitives::{Address, Bytes, B256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::ecosystem::upgrade_full::UpgradeFull;
use crate::commands::ecosystem::upgrade_inner::{CtmInputs, PrepareInputs, UpgradeInner};
use crate::common::abi::AdminFunctionsAbi;
use crate::common::env_config::EnvConfig;
use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::forge::scripts::{
    ADMIN_FUNCTIONS_INVOCATION, CURRENT_CORE_UPGRADE_SCRIPT_PATH, CURRENT_CTM_UPGRADE_SCRIPT_PATH,
    CURRENT_UPGRADE_LOCAL_INPUT_PATH, UPGRADE_CORE_OUTPUT_PATH,
};
use crate::common::forge::ForgeRunner;
use crate::common::governance_calls::GovernanceCallsTable;
use crate::common::logger;
use crate::common::output::write_output_if_requested;
use crate::common::paths;
use crate::common::wallets::Wallet;
use crate::common::SharedRunArgs;

// ── upgrade-governance (the one governance bundle on a fork) ──────────────

/// Replay the package's governance bundle on an anvil fork. Forge's broadcast
/// log records the replay, so the emitted Safe bundle carries the governance
/// call(s) for signers to approve as one Safe transaction.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct UpgradeGovernanceArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemArgs,

    /// Path(s) to TOML(s) carrying a top-level `[governance_calls]` table whose
    /// one key `calls` is the hex-encoded `Call[]` bundle. Typically the single
    /// merged ecosystem TOML written by `upgrade-prepare-all`
    /// (`<out>/ecosystem.toml`); per-script TOMLs (one core + one per CTM)
    /// also work and may be passed multiple times, replayed in the order given.
    /// Every `governanceExecuteCalls` invocation lands in the same Safe bundle
    /// since the governance owner signs each of them.
    #[clap(long, num_args = 1..)]
    pub governance_toml: Vec<PathBuf>,
}

#[derive(Serialize)]
struct UpgradeGovernanceOutput {
    governance_address: String,
}

pub async fn run_upgrade_governance(mut args: UpgradeGovernanceArgs) -> anyhow::Result<()> {
    // ── env preset auto-fills ────────────────────────────────────────
    let env_cfg = args.topology.env_config()?;
    if let Some(ref cfg) = env_cfg {
        let env_out_base = cfg.protocol_ops_out_dir();
        // Default --out to upgrade-envs/.../<env>/protocol-ops/governance
        if args.shared.out.is_none() {
            args.shared.out = Some(env_out_base.join("governance"));
        }
        // Auto-discover the merged ecosystem TOML from the prepare phase
        // output. `upgrade-prepare-all` writes a single `ecosystem.toml`
        // directly at `<env-out>/ecosystem.toml` (canonical tracked path)
        // whose top-level `[governance_calls] calls` is the merged bundle
        // (the merger's appends, core, the derived executor call, the CTM),
        // so we no longer need to merge multiple files at replay time.
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

    let contracts_path = paths::resolve_l1_contracts_path()?;
    let toml_refs: Vec<&Path> = args.governance_toml.iter().map(|p| p.as_path()).collect();

    let governance_address = replay_governance_calls(
        &mut runner,
        &sender,
        &contracts_path,
        bridgehub,
        toml_refs.as_slice(),
        governance_kind,
    )
    .await?;

    let out_payload = UpgradeGovernanceOutput {
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
            "Governance bundle replayed. Output written to: {}",
            out_dir.display()
        ));
    } else {
        logger::outro("Governance bundle replayed.");
    }
    Ok(())
}

// ── governance replay (used by `run_upgrade_governance`) ──────────────────

#[derive(Debug, Deserialize)]
struct EcosystemUpgradeOutput {
    governance_calls: GovernanceCallsTable,
}

/// A governance call the merger appends that no prepare script emitted (the PUH/Guardians
/// wiring, the CTM `acceptOwnership()` normalization). Declared in the merged TOML's
/// `external_actions` exactly like the scripts' own, so the merged bundles never carry a call the
/// artifact does not name.
#[derive(Debug, Clone)]
pub(super) struct ExtraGovernanceCall {
    pub label: &'static str,
    pub authority: &'static str,
    pub call: crate::common::governance_calls::GovernanceCall,
}

alloy::sol! {
    /// The coordinating `EcosystemUpgradeExecutor`'s one entrypoint — the only executor call a
    /// registry-driven package carries. It is a function of the operation's address alone, so the
    /// merge DERIVES it rather than reading it from a prepare bundle.
    interface IEcosystemUpgradeExecutorEntrypoint {
        function execute(address _operation);
    }
}

/// The provenance invariant of one prepare output: every call of its governance bundle IS one of
/// the `external_actions` the script declared for the governance phase — same target, same value,
/// same calldata — and every such declared action appears in it. A script that composes a call it
/// never declared fails the merge instead of shipping it; so does one that declares an action it
/// then omits. The executor call itself is not in any prepare's bundle: the merge derives it from
/// the operation the CTM prepare deployed.
fn check_bundle_provenance(
    source: &str,
    gov: &GovernanceCallsTable,
    declared: &[ExternalAction],
) -> anyhow::Result<()> {
    use crate::common::governance_calls::decode_calls;
    let calls =
        decode_calls(&gov.calls).with_context(|| format!("{source}: decode governance calls"))?;
    let for_phase: Vec<&ExternalAction> = declared
        .iter()
        .filter(|a| a.phase == GOVERNANCE_PHASE)
        .collect();
    // Matched one-for-one rather than by set membership, so a bundle cannot carry a declared call
    // twice over while a second declaration goes unemitted.
    let mut claimed = vec![false; for_phase.len()];
    for call in &calls {
        let matched = for_phase
            .iter()
            .enumerate()
            .position(|(i, action)| !claimed[i] && action.is_call(call));
        match matched {
            Some(i) => claimed[i] = true,
            None => anyhow::bail!(
                "{source}: the governance bundle carries a call no declared external action \
                 accounts for — target {:#x}, value {}, selector 0x{}. Every emitted call must be \
                 a declared action (see ExternalActionsLib); the executor call is derived by the \
                 merge from the operation",
                call.target,
                call.value,
                hex::encode(&call.data[..call.data.len().min(4)])
            ),
        }
    }
    if let Some(i) = claimed.iter().position(|c| !c) {
        anyhow::bail!(
            "{source}: declares a governance external action it never emits — {}",
            for_phase[i].describe()
        );
    }
    Ok(())
}

/// The upgrade's executor call: `EcosystemUpgradeExecutor.execute(operation)` on the coordinator.
/// Nothing about it is authored — it is a pure function of the operation's address, which is why
/// it is computed here instead of being carried through a prepare bundle and re-checked against
/// this same encoding.
fn coordinator_execute_call(
    coordinator: Address,
    operation: Address,
) -> crate::common::governance_calls::GovernanceCall {
    crate::common::governance_calls::GovernanceCall {
        target: coordinator,
        value: alloy::primitives::U256::ZERO,
        data: IEcosystemUpgradeExecutorEntrypoint::executeCall {
            _operation: operation,
        }
        .abi_encode(),
    }
}

/// The `(coordinator, operation)` pair the CTM prepare reported, or `None` when it deployed no
/// operation — a bootstrap edge, which has no transition to associate and drives its own declared
/// bundle instead.
///
/// One operation names one transition, so a package with several CTM prepares would carry several;
/// the prepare boundary already admits exactly one ZKsync OS CTM, and this refuses the rest rather
/// than silently emitting one upgrade's executor call for another's.
fn sole_operation(
    ctm_entries: &[crate::commands::ecosystem::upgrade_inner::CtmPrepareEntry],
) -> anyhow::Result<Option<(Address, Address)>> {
    let mut found: Option<(Address, Address)> = None;
    for entry in ctm_entries {
        let raw = fs::read_to_string(&entry.toml)
            .with_context(|| format!("read {}", entry.toml.display()))?;
        let top: toml::Value =
            toml::from_str(&raw).with_context(|| format!("parse {}", entry.toml.display()))?;
        let read = |key: &str| -> Option<Address> {
            top.get("registry")
                .and_then(|r| r.get(key))
                .and_then(|v| v.as_str())
                .and_then(|v| v.parse::<Address>().ok())
                .filter(|a| !a.is_zero())
        };
        let Some(operation) = read("operation_addr") else {
            continue;
        };
        let coordinator = read("coordinator_addr").with_context(|| {
            format!(
                "{} names operation_addr {operation:#x} but no coordinator_addr to drive it",
                entry.toml.display()
            )
        })?;
        if let Some((_, previous)) = found {
            anyhow::bail!(
                "two CTM prepares reported an operation ({previous:#x} and {operation:#x}); \
                 one upgrade carries exactly one"
            );
        }
        found = Some((coordinator, operation));
    }
    Ok(found)
}

/// Replay the governance bundle of one or more prepared TOMLs, in the order given.
///
/// Each TOML's `[governance_calls] calls` is one `governanceExecuteCalls` (legacy Governance) or
/// `governanceExecuteCallsDirect` (PUH) invocation signed by `sender` (the governance owner), so
/// they merge into one governance Safe bundle. A bootstrap bundle needs no separate completion
/// check: its last call is `RegistryBootstrapMigration.validateApplied()`, so an incomplete edge
/// reverts the replay itself. Returns the resolved governance contract address for diagnostics.
pub async fn replay_governance_calls(
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
    let mut governance_addr = Address::ZERO;
    for toml_path in governance_tomls {
        governance_addr = governance_execute(
            runner,
            sender,
            contracts_path,
            toml_path,
            bridgehub,
            governance_kind,
        )
        .await
        .with_context(|| format!("governance bundle ({})", toml_path.display()))?;
    }
    Ok(governance_addr)
}

fn read_governance_calls(governance_toml: &Path) -> anyhow::Result<String> {
    let toml_content = fs::read_to_string(governance_toml).with_context(|| {
        format!(
            "Failed to read governance TOML: {}",
            governance_toml.display()
        )
    })?;
    let upgrade_output: EcosystemUpgradeOutput =
        toml::from_str(&toml_content).context("Failed to parse governance TOML")?;
    Ok(upgrade_output.governance_calls.calls)
}

async fn governance_execute(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    _contracts_path: &Path,
    governance_toml: &Path,
    bridgehub: Address,
    governance_kind: crate::common::env_config::GovernanceKind,
) -> anyhow::Result<Address> {
    let encoded_calls_hex = read_governance_calls(governance_toml)?;

    let governance_addr =
        crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
            .await
            .context("Failed to auto-resolve governance address from bridgehub")?;
    logger::info(format!(
        "Governance (auto-resolved): {:#x}",
        governance_addr
    ));

    // An empty bundle is skipped rather than replayed as an empty governance operation, which
    // a second empty TOML under the same legacy-Gov salt would schedule a second time.
    if crate::common::governance_calls::decode_calls(&encoded_calls_hex)
        .context("decode governance calls")?
        .is_empty()
    {
        logger::info(format!(
            "Governance bundle ({}) carries no calls: nothing to execute",
            governance_toml.display()
        ));
        return Ok(governance_addr);
    }
    let encoded_calls = Bytes::from(
        hex::decode(encoded_calls_hex.trim_start_matches("0x"))
            .context("invalid governance calls hex")?,
    );
    let calldata = match governance_kind {
        crate::common::env_config::GovernanceKind::Legacy => {
            AdminFunctionsAbi::governanceExecuteCallsCall {
                _callsToExecute: encoded_calls,
                _governanceAddr: governance_addr,
            }
            .abi_encode()
        }
        crate::common::env_config::GovernanceKind::Puh => {
            AdminFunctionsAbi::governanceExecuteCallsDirectCall {
                _callsToExecute: encoded_calls,
                _governanceAddr: governance_addr,
            }
            .abi_encode()
        }
    };
    let script = runner
        .script_with_calldata(&ADMIN_FUNCTIONS_INVOCATION, calldata)
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(sender);

    logger::step(format!(
        "Running the governance bundle ({})",
        governance_toml.display()
    ));
    logger::info(format!("Governance address: {:#x}", governance_addr));

    runner
        .run(script)
        .context("Failed to execute forge script for the governance bundle")?;

    logger::success("Governance bundle executed");
    Ok(governance_addr)
}

// ── upgrade-prepare-all (split-flow orchestrator) ──────────────────────────

/// Unified split-flow prepare. Runs the core script's `noGovernancePrepare` once
/// and the CTM script's `noGovernancePrepare` for the target `--ctm-proxy`, all on a
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

    /// Target CTM to upgrade. Only a ZKsync OS CTM can be targeted on this
    /// release. It must have at least one registered chain so rollup-DA-manager
    /// auto-resolution works.
    #[clap(long = "ctm-proxy")]
    pub ctm_proxy: Option<Address>,

    #[clap(long)]
    pub create2_factory_salt: Option<B256>,

    #[clap(
        long,
        default_value = CURRENT_UPGRADE_LOCAL_INPUT_PATH
    )]
    pub upgrade_input_path: String,

    /// Override the core-prepare output TOML path (relative to l1-contracts
    /// root). Defaults to the canonical `script-out/upgrade-core.toml`.
    #[clap(long, default_value = UPGRADE_CORE_OUTPUT_PATH, hide = true)]
    pub core_output_path: String,

    /// Core upgrade script; historical releases must select their own script and input.
    #[clap(long, default_value = CURRENT_CORE_UPGRADE_SCRIPT_PATH)]
    pub core_script_path: String,

    /// CTM upgrade script; historical releases must select their own script and input.
    #[clap(long, default_value = CURRENT_CTM_UPGRADE_SCRIPT_PATH)]
    pub ctm_script_path: String,

    /// Path to a TOML file describing the CTM inputs (proxy + optional
    /// overrides). Mutually exclusive with the direct CTM flags
    /// (`--ctm-proxy`,
    /// `--rollup-da-manager-address`). The file must contain exactly one CTM,
    /// and anything that is not a ZKsync OS CTM fails the prepare.
    ///
    /// Schema:
    /// ```toml
    /// [[ctm]]
    /// proxy = "0x..."
    /// rollup_da_manager  = "0x..."           # optional
    /// ```
    #[clap(long, conflicts_with_all = [
        "ctm_proxy",
        "rollup_da_manager_address",
    ])]
    pub ctm_config: Option<PathBuf>,

    /// Override the rollup DA manager address. Auto-resolved from a
    /// representative ZK chain on the CTM when omitted. There is no bytecodes-supplier
    /// counterpart: the prepare script reads that off the CTM's own
    /// `L1_BYTECODES_SUPPLIER()` immutable.
    #[clap(long)]
    pub rollup_da_manager_address: Option<Address>,
}

#[derive(Debug, Deserialize)]
struct CtmConfigFile {
    #[serde(rename = "ctm", default)]
    ctms: Vec<CtmConfigEntry>,
}

#[derive(Debug, Deserialize)]
struct CtmConfigEntry {
    proxy: Address,
    #[serde(default)]
    rollup_da_manager: Option<Address>,
}

#[derive(Serialize)]
struct UpgradePrepareAllOutput {
    core_governance_toml: String,
    ctm_governance_tomls: Vec<CtmGovernanceTomlEntry>,
    /// Merged ecosystem TOML written to `<env-out>/ecosystem.toml`, when
    /// `--out` is set. Contains top-level `[governance_calls] calls` (the
    /// merged bundle), `[core]` (the CTM-agnostic core prepare output), and one
    /// `[ctms.zksync_os]` table carrying the CTM diamond cut +
    /// contracts config (this release only upgrades ZKsyncOS CTMs). Downstream
    /// `upgrade-governance --env <env>` and `verify-bootstrap` both consume
    /// this single file.
    #[serde(skip_serializing_if = "Option::is_none")]
    merged_ecosystem_toml: Option<String>,
    puh_proxy: String,
    new_puh_impl: String,
    new_guardians: String,
    new_security_council: String,
    new_emergency_upgrade_board: String,
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
        "# `rollup_da_manager` is commented out so the prepare flow auto-resolves it\n\
         # from a chain registered on the CTM.\n",
    );
    for (proxy, witness_chain) in &ctms {
        out.push_str("\n[[ctm]]\n");
        out.push_str(&format!(
            "# witness chain (any chain registered on this CTM): {witness_chain}\n"
        ));
        out.push_str(&format!("proxy = \"{proxy:#x}\"\n"));
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

/// The `--env` preset for `upgrade-prepare-all`, from the release dir `--upgrade-env-dir` selects (the current
/// release's by default). That dir is the only release selector: an explicit `--upgrade-input-path` must sit in
/// it, so the input, the CREATE2 salts and the output dir always belong to the same release.
fn prepare_env_config(args: &UpgradePrepareAllArgs) -> anyhow::Result<Option<EnvConfig>> {
    let Some(cfg) = args.topology.env_config()? else {
        return Ok(None);
    };
    if args.upgrade_input_path != CURRENT_UPGRADE_LOCAL_INPUT_PATH {
        let input_dir = paths::resolve_l1_contracts_path()?
            .join(args.upgrade_input_path.trim_start_matches('/'))
            .parent()
            .map(Path::to_path_buf)
            .context("--upgrade-input-path has no parent directory")?;
        let env_dir = cfg
            .upgrade_input_path
            .parent()
            .context("env input has no parent directory")?;
        anyhow::ensure!(
            input_dir == env_dir,
            "--upgrade-input-path {} is not in the release dir {} that --env {} reads its salts and owner from; \
             select that release with --upgrade-env-dir instead",
            args.upgrade_input_path,
            env_dir.display(),
            cfg.env
        );
    }
    Ok(Some(cfg))
}

/// The env's upgrade input (`/<release dir>/<env>.toml`, relative to `l1-contracts/`) from the release dir
/// `cfg` was loaded from, so the input, the salts and the output dir belong to the same release.
///
/// Fails closed on a missing file rather than keeping the CLI default. The default is the *local* input, so a
/// silent fallback would hand a real environment local's values for the keys the input does supply —
/// `era_chain_id`, for one. Failing here also catches a mistyped `--env`.
fn per_env_upgrade_input(cfg: &EnvConfig) -> anyhow::Result<String> {
    let per_env_abs = &cfg.upgrade_input_path;
    anyhow::ensure!(
        per_env_abs.exists(),
        "no upgrade input for --env {} at {}. Add it — an empty file is fine if the environment needs \
         nothing from the input — because this command will not fall back to the local default, which \
         would silently give this environment local's `era_chain_id`.",
        cfg.env,
        per_env_abs.display()
    );
    let relative = per_env_abs
        .strip_prefix(paths::resolve_l1_contracts_path()?)
        .with_context(|| format!("{} is outside l1-contracts", per_env_abs.display()))?;
    Ok(format!("/{}", relative.display()))
}

pub async fn run_upgrade_prepare_all(mut args: UpgradePrepareAllArgs) -> anyhow::Result<()> {
    // ── env preset auto-fills ────────────────────────────────────────
    let env_cfg = prepare_env_config(&args)?;
    if let Some(ref cfg) = env_cfg {
        // Default --out to the environment preset's protocol-ops preparation directory.
        if args.shared.out.is_none() {
            args.shared.out = Some(cfg.protocol_ops_out_dir().join("prepare"));
        }
        // Note: we intentionally do *not* default `--deployer-address` from
        // the env's `owner_address`. On stage / mainnet the env's
        // `owner_address` is the ProtocolUpgradeHandler (a contract owned by
        // governance) — it's the *semantic* owner of the ecosystem, not the
        // EOA that signs deployment txs. Using it as the broadcaster only
        // works on a fork via `anvil_impersonateAccount`; on a real chain
        // nobody can sign as that contract. The caller must pass
        // `--deployer-address <real-EOA>` (or derive it from the broadcast
        // signer's private key with `cast wallet address`).
        // Resolve --upgrade-input-path from --env, unless the caller passed one explicitly
        // (see `per_env_upgrade_input`).
        if args.upgrade_input_path == CURRENT_UPGRADE_LOCAL_INPUT_PATH {
            let per_env_rel = per_env_upgrade_input(cfg)?;
            logger::info(format!("Using per-env upgrade input: {per_env_rel}"));
            args.upgrade_input_path = per_env_rel;
        }
    }
    // Auto-fill the CREATE2 salt from the per-version upgrade input
    // (`<current upgrade-env dir>/<env>.toml [contracts]
    // create2_factory_salt`). Recording the salt in version control makes
    // re-prepares reproducible (same addresses every run regardless of who
    // runs it), so deployer-bundle broadcasts can land at addresses that
    // match a later re-prepare's references. Caller can still override
    // with explicit `--create2-factory-salt`.
    if args.create2_factory_salt.is_none() {
        if let Some(cfg) = env_cfg.as_ref() {
            if let Some(salt) = cfg.create2_factory_salt_for_upgrade()? {
                logger::info(format!(
                    "Using create2_factory_salt from {}: {salt:#x}",
                    cfg.upgrade_input_path.display(),
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
        if let Some(salt) = cfg.legacy_gov_salt_for_upgrade()? {
            logger::info(format!(
                "Using legacy_gov_salt from {}: {salt:#x}",
                cfg.upgrade_input_path.display(),
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
    let ctms = if let Some(cfg_path) = &args.ctm_config {
        load_ctm_config(cfg_path)?
    } else if let Some(proxy) = args.ctm_proxy {
        vec![CtmInputs {
            proxy,
            rollup_da_manager: args.rollup_da_manager_address,
        }]
    } else if let Some(ref cfg) = env_cfg {
        let entries = cfg.ctms();
        if entries.is_empty() {
            anyhow::bail!(
                "permanent-values/{}.toml has no [[ctm_contracts.ctms]] entries — fill them in or pass --ctm-config / --ctm-proxy explicitly",
                cfg.env
            );
        }
        let ctms = entries
            .iter()
            .map(|e| CtmInputs {
                proxy: e.proxy,
                rollup_da_manager: e.rollup_da_manager,
            })
            .collect::<Vec<_>>();
        ctms
    } else {
        anyhow::bail!(
            "either --ctm-config, --ctm-proxy, or --env <name> (with [[ctm_contracts.ctms]] in permanent-values) must be provided"
        );
    };
    if ctms.len() != 1 {
        anyhow::bail!(
            "this release prepares exactly one ZKsync OS CTM; received {} entries",
            ctms.len()
        );
    }

    let bridgehub = args.topology.resolve()?;
    let zk_token_asset_id = match env_cfg.as_ref() {
        Some(cfg) => cfg.require_zk_token_asset_id()?,
        None => {
            crate::types::L1Network::from_l1_rpc(&args.shared.l1_rpc_url)?.zk_token_asset_id()?
        }
    };
    // Declared per environment: true everywhere except mainnet. Required rather than defaulted —
    // guessing it wrong installs a verifier that accepts unproven batches.
    let testnet_verifier = match env_cfg.as_ref() {
        Some(cfg) => cfg.testnet_verifier().ok_or_else(|| {
            anyhow::anyhow!(
                "permanent-values/{}.toml is missing top-level `testnet_verifier`; it must be \
                 declared explicitly (true for every env except mainnet)",
                cfg.env
            )
        })?,
        None => {
            logger::info(
                "No --env given: assuming a local/anvil ecosystem and the testnet verifier"
                    .to_string(),
            );
            true
        }
    };

    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(deployer_address).await?;

    let contracts_path = paths::resolve_l1_contracts_path()?;

    let create2_factory_salt_per_ctm = match env_cfg.as_ref() {
        Some(cfg) => {
            let map = cfg.create2_factory_salt_for_upgrade_per_ctm()?;
            if map.is_empty() {
                None
            } else {
                logger::info(format!(
                    "Using {} per-CTM create2 salts from {}",
                    map.len(),
                    cfg.upgrade_input_path.display()
                ));
                Some(map)
            }
        }
        None => None,
    };

    let inputs = PrepareInputs {
        ctms,
        create2_factory_salt: args.create2_factory_salt,
        create2_factory_salt_per_ctm,
        upgrade_input_path: args.upgrade_input_path.clone(),
        core_output_path: args.core_output_path.clone(),
        core_script_path: args.core_script_path.clone(),
        ctm_script_path: args.ctm_script_path.clone(),
        zk_token_asset_id,
        testnet_verifier,
    };
    let proxies: Vec<crate::common::env_config::OwnableProxyEntry> = env_cfg
        .as_ref()
        .map(|cfg| cfg.ownable_proxies().to_vec())
        .unwrap_or_default();
    let full = UpgradeFull::new(UpgradeInner::new(&contracts_path, bridgehub))
        .with_ownable_proxies(proxies);
    let prepared = full.prepare(&mut runner, &deployer, &inputs).await?;

    // `ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps` wrote one
    // `acceptOwnership()` Call per Ownable2Step CTM whose pendingOwner is PUH.
    // Those calls must execute as PUH via the governance ceremony — prepended
    // to the governance bundle below, after the PUH/Guardians redeploy calls.
    let pre_gov_accept_calls = read_pre_governance_accept_ownership_calls(&contracts_path)?;

    // Phase 1b on the same fork: redeploy ProtocolUpgradeHandler + Guardians
    // and capture the governance calls that wire them into the live PUH proxy.
    //
    // Two conditions, and both are necessary. `governance_kind == puh` says the
    // ecosystem HAS a PUH to redeploy — legacy-Governance envs (e.g. testnet's
    // internal `0xc4fd…` bridgehub owned by ZKsync `Governance.sol`) do not, so
    // there is nothing to do there. But that is a permanent property of the
    // ecosystem, not a statement that THIS release replaces its governance set:
    // gating on it alone made every recurring preparation on a PUH env redeploy
    // the whole governance set and fold four wiring calls into the bundle. The
    // release's own env input declares the intent, per env, in the directory that
    // moves with the release — so a later release simply omits the key and
    // redeploys nothing.
    let governance_kind = env_cfg
        .as_ref()
        .map(|c| c.governance_kind())
        .unwrap_or_default();
    let is_puh_governed = governance_kind == crate::common::env_config::GovernanceKind::Puh;
    let redeploy_declared = env_cfg
        .as_ref()
        .map(|c| c.redeploys_zk_governance())
        .transpose()?
        .unwrap_or(false);
    // Every prepared CTM is ZKsync OS (prepare rejects anything else); the first
    // one in input order is the representative passed to the PUH redeploy.
    let zksync_os_ctm_proxy = prepared.ctm_tomls.first().map(|e| e.proxy);
    let redeploy_zk_governance =
        zk_governance_redeploy_decision(governance_kind, redeploy_declared)?;
    let puh_outcome = if redeploy_zk_governance {
        let mut puh_inputs =
            crate::commands::ecosystem::zk_governance::ZkGovernanceInputs::from_env(
                env_cfg.as_ref(),
                bridgehub,
            );
        puh_inputs.zksync_os_ctm = zksync_os_ctm_proxy;
        Some(
            crate::commands::ecosystem::zk_governance::deploy_puh_guardians(
                &mut runner,
                &deployer,
                &puh_inputs,
            )
            .await
            .context("PUH/Guardians redeploy step")?,
        )
    } else if is_puh_governed {
        logger::info(
            "Skipping PUH/Guardians redeploy (the upgrade input does not declare `redeploy_zk_governance = true`)",
        );
        None
    } else {
        logger::info(
            "Skipping PUH/Guardians redeploy (governance_kind != \"puh\" — env uses legacy Governance.sol)",
        );
        None
    };

    // Merge the in-memory PUH/Guardians wiring (when present) + core + per-CTM
    // governance calls into a single `<env-out>/ecosystem.toml`. The Solidity
    // scripts each emit their own toml under `script-out/` (forge
    // requirement), but downstream (verification + governance replay) only
    // consumes the merged file.
    // Write the merged TOML straight to the canonical tracked path
    // (`<env-out>/ecosystem.toml`) — that's the file reviewers diff and the
    // path every downstream consumer (the verifier, simulator emitter, fork
    // tests) reads from. The `prepare/` subtree under `--out` keeps the per-bundle
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
        let mut extras: Vec<ExtraGovernanceCall> = puh_outcome
            .as_ref()
            .map(|o| {
                o.wiring_calls
                    .iter()
                    .cloned()
                    .map(|call| ExtraGovernanceCall {
                        label: "PUH/Guardians redeploy wiring (zk_governance)",
                        authority: "protocol governance (PUH self-upgrade)",
                        call,
                    })
                    .collect()
            })
            .unwrap_or_default();
        extras.extend(
            pre_gov_accept_calls
                .iter()
                .cloned()
                .map(|call| ExtraGovernanceCall {
                    label: "acceptOwnership() on a CTM whose pending owner is governance",
                    authority: "protocol governance",
                    call,
                }),
        );
        write_merged_ecosystem_toml(
            &prepared.core_toml,
            &prepared.ctm_tomls,
            &extras,
            puh_outcome.as_ref(),
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
        new_security_council: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.new_security_council))
            .unwrap_or_default(),
        new_emergency_upgrade_board: puh_outcome
            .as_ref()
            .map(|o| format!("{:#x}", o.new_emergency_upgrade_board))
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

/// Merge the core + per-CTM prepare TOMLs, the derived coordinator call and the merger's own
/// extras (the in-memory PUH/Guardians wiring and the CTM `acceptOwnership()` normalization) into
/// a single ecosystem TOML at `dst`.
///
/// The merger COMPOSES nothing. The one bundle is, in order: the extras (they must precede a
/// bootstrap's `ctm.transferOwnership(migration)`, which assumes governance already owns the
/// CTM), the core prepare's declared calls, the DERIVED `coordinator.execute(operation)` (recurring
/// upgrades only), then the CTM prepare's declared calls. Every call other than the derived one is
/// declared in `external_actions` with phase `governance`; a prepare bundle carrying a call the
/// artifact does not name fails the merge (`check_bundle_provenance`). Shape:
///
/// ```toml
/// [[external_actions]]            # every governance/admin call that is NOT the executor call,
/// phase = "governance"            # carrying the call itself (see `common::external_actions`)
/// label = "…"
/// authority = "…"
/// target = "0x…"
/// value = "0"
/// data = "0x…"
///
/// [governance_calls]              # the one bundle: extras, core actions, the DERIVED
/// calls = "0x..."                 # execute(operation) (registry-driven only), CTM actions
///
/// [operation]                     # registry-driven upgrades only: the operation the CTM
/// operation_addr = "0x..."        # prepare deployed, and the coordinator its executor call
/// coordinator_addr = "0x..."      # is derived on
///
/// [core]                          # whole core TOML minus its [governance_calls]
/// ...
///
/// [ctms.zksync_os]                # whole CTM TOML minus its [governance_calls];
/// ...                             # one section per ZKsyncOS CTM.
/// ...
///
/// [zk_governance]                 # only when the PUH governance set was redeployed
/// new_puh_impl = "0x..."
/// new_guardians = "0x..."
/// new_security_council = "0x..."
/// new_emergency_upgrade_board = "0x..."
/// ```
fn write_merged_ecosystem_toml(
    core_toml: &Path,
    ctm_entries: &[crate::commands::ecosystem::upgrade_inner::CtmPrepareEntry],
    extras: &[ExtraGovernanceCall],
    zk_governance: Option<&crate::commands::ecosystem::zk_governance::ZkGovernanceOutcome>,
    dst: &Path,
) -> anyhow::Result<()> {
    use toml::value::Value;

    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let operation = sole_operation(ctm_entries)?;
    let mut ctm_outputs = Vec::with_capacity(ctm_entries.len());
    for entry in ctm_entries {
        ctm_outputs.push((entry.proxy, load_prepare_output(&entry.toml)?));
    }
    let mut doc = merge_prepare_outputs(
        load_prepare_output(core_toml)?,
        ctm_outputs,
        operation,
        extras,
    )?;
    if let Some(zk_governance) = zk_governance {
        let mut table = toml::value::Table::new();
        table.insert(
            "new_puh_impl".into(),
            Value::String(format!("{:#x}", zk_governance.new_puh_impl)),
        );
        table.insert(
            "new_guardians".into(),
            Value::String(format!("{:#x}", zk_governance.new_guardians)),
        );
        table.insert(
            "new_security_council".into(),
            Value::String(format!("{:#x}", zk_governance.new_security_council)),
        );
        table.insert(
            "new_emergency_upgrade_board".into(),
            Value::String(format!("{:#x}", zk_governance.new_emergency_upgrade_board)),
        );
        // `[misc]` stays last.
        let misc = doc.remove("misc");
        doc.insert("zk_governance".into(), Value::Table(table));
        if let Some(misc) = misc {
            doc.insert("misc".into(), misc);
        }
    }

    let body = format!(
        "# Auto-generated by `protocol-ops ecosystem upgrade-prepare-all`.\n\
         # Merged ecosystem upgrade artifact: top-level [governance_calls] calls is\n\
         # the one governance bundle of {} prepare TOML(s) — the merger's extras,\n\
         # the prepares' calls in source order and the derived executor call,\n\
         # never composed here; `external_actions` names every call in it that is\n\
         # not `EcosystemUpgradeExecutor.execute(operation)`.\n\
         # [core] mirrors the\n\
         # core prepare output (minus its own [governance_calls]); [ctms.zksync_os]\n\
         # mirrors the ZKsyncOS CTM prepare output\n\
         # for downstream verification. [misc] carries shared metadata used\n\
         # by verification. When [zk_governance] is present, it names\n\
         # the zk-governance contracts the bundle wires in.\n\n{}",
        1 + ctm_entries.len(),
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

/// One prepare output split into its body, its governance bundle and its declared actions.
struct PrepareOutputParts {
    body: toml::value::Table,
    gov: GovernanceCallsTable,
    /// The script's declared `external_actions` (see `ExternalActionsLib.serialize`).
    external_actions: Vec<ExternalAction>,
}

/// Reads a prepare output and pops its `[governance_calls]` (always present) and
/// `external_actions` out, so governance can be merged at top level.
fn load_prepare_output(path: &Path) -> anyhow::Result<PrepareOutputParts> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut value: toml::value::Table =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    let gov = value
        .remove("governance_calls")
        .with_context(|| format!("missing [governance_calls] in {}", path.display()))?;
    let gov: GovernanceCallsTable = gov
        .try_into()
        .with_context(|| format!("invalid [governance_calls] in {}", path.display()))?;
    let external_actions: Vec<ExternalAction> = value
        .remove("external_actions")
        .map(|v| {
            v.try_into()
                .with_context(|| format!("invalid external_actions in {}", path.display()))
        })
        .transpose()?
        .unwrap_or_default();
    Ok(PrepareOutputParts {
        body: value,
        gov,
        external_actions,
    })
}

/// The merged document of [`write_merged_ecosystem_toml`] minus `[zk_governance]`, in the
/// order `toml::to_string` writes it: `external_actions`, `[governance_calls]`, `[core]`,
/// `[ctms.*]`, the optional `[operation]`, and `[misc]` last.
fn merge_prepare_outputs(
    core: PrepareOutputParts,
    ctms: Vec<(Address, PrepareOutputParts)>,
    operation: Option<(Address, Address)>,
    extras: &[ExtraGovernanceCall],
) -> anyhow::Result<toml::value::Table> {
    use crate::common::governance_calls::{encode_calls, merge_call_array_hex};
    use toml::value::{Table, Value};

    let PrepareOutputParts {
        body: mut core_body,
        gov: core_gov,
        external_actions: core_actions,
    } = core;
    check_bundle_provenance("core prepare", &core_gov, &core_actions)?;
    let misc_body = match core_body.remove("misc") {
        Some(Value::Table(table)) => Some(table),
        Some(other) => anyhow::bail!(
            "[misc] in the core prepare output must be a table (got {})",
            other.type_str()
        ),
        None => None,
    };

    let extra_calls: Vec<_> = extras.iter().map(|e| e.call.clone()).collect();
    let mut external_actions: Vec<ExternalAction> = extras
        .iter()
        .map(|e| ExternalAction::governance(e.label, e.authority, &e.call))
        .collect();
    external_actions.extend(core_actions);
    let mut chunks: Vec<String> = vec![
        format!("0x{}", hex::encode(encode_calls(&extra_calls))),
        core_gov.calls,
    ];

    // The executor call over the operation the CTM prepare deployed, DERIVED from its address and
    // ordered after the core prepare's declared actions and before the CTM's. A bootstrap edge
    // deploys no operation (it has no transition) and names none.
    let operation_body: Option<Table> = operation.map(|(coordinator, operation)| {
        let call = coordinator_execute_call(coordinator, operation);
        chunks.push(format!("0x{}", hex::encode(encode_calls(&[call]))));
        let mut table = Table::new();
        table.insert(
            "operation_addr".into(),
            Value::String(format!("{operation:#x}")),
        );
        table.insert(
            "coordinator_addr".into(),
            Value::String(format!("{coordinator:#x}")),
        );
        table
    });

    // `UpgradeInner::prepare` rejects any non-ZKsync-OS CTM, so every CTM that
    // reaches the merge is ZKsync OS. The merge keys per-CTM sections by the fixed
    // `zksync_os` label, so two CTMs in one upgrade collide here.
    let mut ctms_table = Table::new();
    for (proxy, ctm) in ctms {
        let label = "zksync_os";
        if ctms_table.contains_key(label) {
            anyhow::bail!(
                "duplicate CTM section `{label}`: a single upgrade merges at most one ZKsyncOS CTM"
            );
        }
        check_bundle_provenance(
            &format!("CTM prepare {proxy:#x}"),
            &ctm.gov,
            &ctm.external_actions,
        )?;
        external_actions.extend(ctm.external_actions);
        ctms_table.insert(label.to_string(), Value::Table(ctm.body));
        chunks.push(ctm.gov.calls);
    }

    let mut governance_calls_table = Table::new();
    governance_calls_table.insert(
        "calls".into(),
        Value::String(merge_call_array_hex(
            &chunks.iter().map(String::as_str).collect::<Vec<_>>(),
        )?),
    );

    let mut doc = Table::new();
    doc.insert(
        "external_actions".into(),
        Value::try_from(&external_actions).context("serialize the merged external actions")?,
    );
    doc.insert(
        "governance_calls".into(),
        Value::Table(governance_calls_table),
    );
    doc.insert("core".into(), Value::Table(core_body));
    doc.insert("ctms".into(), Value::Table(ctms_table));
    if let Some(body) = operation_body {
        doc.insert("operation".into(), Value::Table(body));
    }
    if let Some(body) = misc_body {
        doc.insert("misc".into(), Value::Table(body));
    }
    Ok(doc)
}

/// Read the `acceptOwnership()` Call list written by
/// `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
/// (in `<l1-contracts>/script-out/pre-governance-accept-ownerships.toml`).
/// Returns an empty vector when the file doesn't exist (e.g. a prior regen
/// without this step) — the merge step then has nothing to prepend.
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

/// Read the multi-CTM config TOML and return per-CTM inputs. This release
/// only upgrades ZKsyncOS CTMs; prepare fails on anything else.
fn load_ctm_config(path: &Path) -> anyhow::Result<Vec<CtmInputs>> {
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

    let ctms: Vec<CtmInputs> = parsed
        .ctms
        .into_iter()
        .map(|e| CtmInputs {
            proxy: e.proxy,
            rollup_da_manager: e.rollup_da_manager,
        })
        .collect();

    Ok(ctms)
}

/// Whether this preparation replaces the ecosystem's governance set (see
/// [`crate::commands::ecosystem::zk_governance`]).
///
/// Both inputs are necessary and neither is sufficient. `governance_kind` says the ecosystem HAS a
/// `ProtocolUpgradeHandler` — a permanent property, true of every release prepared for that env, so
/// gating on it alone made every RECURRING preparation on a PUH env redeploy the whole governance
/// set and fold four wiring calls into the governance bundle. `redeploy_declared` is the release's
/// own statement that it intends to. Declared-but-impossible is a misconfiguration to name, not to
/// skip past: silently doing nothing would hide a release that thinks it is replacing governance.
///
/// Extracted from the prepare flow so this decision is exercised without a fork — the `--env`
/// branch that reaches it has no end-to-end gate.
fn zk_governance_redeploy_decision(
    governance_kind: crate::common::env_config::GovernanceKind,
    redeploy_declared: bool,
) -> anyhow::Result<bool> {
    let is_puh_governed = governance_kind == crate::common::env_config::GovernanceKind::Puh;
    if redeploy_declared && !is_puh_governed {
        anyhow::bail!(
            "the upgrade input declares `redeploy_zk_governance = true`, but this env's \
             `governance_kind` is not \"puh\": there is no ProtocolUpgradeHandler to redeploy"
        );
    }
    Ok(is_puh_governed && redeploy_declared)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::env_config::GovernanceKind;

    /// A PUH-governed env is not by itself a reason to replace its governance set: only the
    /// release's own declaration is. Every recurring preparation used to take the first for the
    /// second.
    #[test]
    fn the_governance_redeploy_needs_both_a_puh_env_and_a_declaration() {
        assert!(!zk_governance_redeploy_decision(GovernanceKind::Puh, false).unwrap());
        assert!(!zk_governance_redeploy_decision(GovernanceKind::Legacy, false).unwrap());
        assert!(zk_governance_redeploy_decision(GovernanceKind::Puh, true).unwrap());

        let err = zk_governance_redeploy_decision(GovernanceKind::Legacy, true).expect_err(
            "declaring the redeploy on a legacy-governance env must be named, not skipped",
        );
        assert!(err.to_string().contains("redeploy_zk_governance"), "{err}");
    }
    use crate::common::governance_calls::{encode_calls, GovernanceCall};

    fn call(target: u8, data: &[u8]) -> GovernanceCall {
        GovernanceCall {
            target: Address::repeat_byte(target),
            value: alloy::primitives::U256::ZERO,
            data: data.to_vec(),
        }
    }

    fn bundle_hex(calls: &[GovernanceCall]) -> String {
        format!("0x{}", hex::encode(encode_calls(calls)))
    }

    fn gov(calls: &[GovernanceCall]) -> GovernanceCallsTable {
        GovernanceCallsTable {
            calls: bundle_hex(calls),
        }
    }

    #[test]
    fn a_bundle_of_exactly_the_declared_actions_passes() {
        let emitted = [call(0x11, &[0xaa]), call(0x22, &[0xbb])];
        let declared: Vec<ExternalAction> = emitted
            .iter()
            .map(|c| ExternalAction::governance("l", "a", c))
            .collect();
        check_bundle_provenance("t", &gov(&emitted), &declared).expect("identical bundle");
    }

    /// The defect a headcount cannot see: the script declares one action and emits a different
    /// call, in equal numbers.
    #[test]
    fn a_substituted_call_fails_even_at_the_declared_count() {
        let declared = vec![ExternalAction::governance("l", "a", &call(0x11, &[0xaa]))];
        let err = check_bundle_provenance("t", &gov(&[call(0x11, &[0xbb])]), &declared)
            .expect_err("substituted calldata must fail");
        assert!(
            err.to_string().contains("no declared external action"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_declared_action_that_is_never_emitted_fails() {
        let declared = vec![ExternalAction::governance("l", "a", &call(0x11, &[0xaa]))];
        let err = check_bundle_provenance("t", &gov(&[]), &declared)
            .expect_err("an unemitted declaration must fail");
        assert!(
            err.to_string().contains("never emits"),
            "unexpected error: {err}"
        );
    }

    /// The executor call is the coordinator as target, no value, and `execute(address)` over the
    /// operation. The selector is transcribed rather than re-derived from the same `sol!` block the
    /// code under test uses, so this is a real check of the encoding and not of itself.
    #[test]
    fn the_derived_call_is_execute_on_the_coordinator() {
        let coordinator = Address::repeat_byte(0xc0);
        let operation = Address::repeat_byte(0x0b);
        let mut expected = vec![0x4b, 0x64, 0xe4, 0x92];
        expected.extend_from_slice(&[0u8; 12]);
        expected.extend_from_slice(operation.as_slice());

        let derived = coordinator_execute_call(coordinator, operation);
        assert_eq!(derived.target, coordinator);
        assert!(derived.value.is_zero());
        assert_eq!(derived.data, expected);
        assert_eq!(
            &alloy::primitives::keccak256(b"execute(address)")[..4],
            &expected[..4]
        );
    }

    /// An `admin` action rides no governance bundle, so it does not account for one of its calls.
    #[test]
    fn an_admin_action_does_not_account_for_a_bundle_call() {
        let emitted = [call(0x11, &[0xaa])];
        let mut declared = ExternalAction::governance("l", "a", &emitted[0]);
        declared.phase = "admin".to_string();
        check_bundle_provenance("t", &gov(&emitted), &[declared])
            .expect_err("an admin declaration cannot cover a governance call");
    }

    fn prepare_output(calls: &[GovernanceCall]) -> PrepareOutputParts {
        PrepareOutputParts {
            body: toml::value::Table::new(),
            gov: gov(calls),
            external_actions: calls
                .iter()
                .map(|c| ExternalAction::governance("declared", "governance", c))
                .collect(),
        }
    }

    fn merged_bundle(doc: &toml::value::Table) -> Vec<GovernanceCall> {
        let hex = doc["governance_calls"]["calls"].as_str().unwrap();
        crate::common::governance_calls::decode_calls(hex).unwrap()
    }

    /// The one bundle's order: the merger's extras first — a bootstrap's
    /// `ctm.transferOwnership(migration)` assumes governance already accepted the CTM — then the
    /// core prepare's calls, the derived `execute(operation)`, then the CTM prepare's calls.
    /// Every call but the derived one is declared, the extras included.
    #[test]
    fn the_merged_bundle_runs_extras_core_execute_then_ctm() {
        let extra = call(0xe1, &[0x01]);
        let core = call(0xc1, &[0x02]);
        let ctm = call(0xd1, &[0x03]);
        let coordinator = Address::repeat_byte(0xc0);
        let operation = Address::repeat_byte(0x0b);
        let doc = merge_prepare_outputs(
            prepare_output(std::slice::from_ref(&core)),
            vec![(
                Address::repeat_byte(0x77),
                prepare_output(std::slice::from_ref(&ctm)),
            )],
            Some((coordinator, operation)),
            &[ExtraGovernanceCall {
                label: "extra",
                authority: "protocol governance",
                call: extra.clone(),
            }],
        )
        .unwrap();

        let bundle = merged_bundle(&doc);
        let execute = coordinator_execute_call(coordinator, operation);
        let order: Vec<(Address, Vec<u8>)> =
            bundle.iter().map(|c| (c.target, c.data.clone())).collect();
        assert_eq!(
            order,
            vec![
                (extra.target, extra.data.clone()),
                (core.target, core.data.clone()),
                (execute.target, execute.data.clone()),
                (ctm.target, ctm.data.clone()),
            ]
        );
        assert_eq!(
            doc["governance_calls"].as_table().unwrap().len(),
            1,
            "the bundle is the table's one key"
        );
        let declared: Vec<ExternalAction> = doc["external_actions"].clone().try_into().unwrap();
        assert_eq!(declared.len(), 3);
        assert!(declared.iter().all(|a| a.phase == GOVERNANCE_PHASE));
        for (i, c) in bundle.iter().enumerate() {
            let is_declared = declared.iter().any(|a| a.is_call(c));
            assert_eq!(is_declared, i != 2, "call {i}");
        }
        assert_eq!(
            doc["operation"]["operation_addr"].as_str().unwrap(),
            format!("{operation:#x}")
        );
    }

    /// A bootstrap edge deploys no operation: no executor call is derived and no `[operation]`
    /// section is written, so the bundle is the extras followed by the prepares' declared calls.
    #[test]
    fn a_bootstrap_merge_derives_no_executor_call() {
        let extra = call(0xe1, &[0x01]);
        let ctm = call(0xd1, &[0x03]);
        let doc = merge_prepare_outputs(
            prepare_output(&[]),
            vec![(
                Address::repeat_byte(0x77),
                prepare_output(std::slice::from_ref(&ctm)),
            )],
            None,
            &[ExtraGovernanceCall {
                label: "extra",
                authority: "protocol governance",
                call: extra.clone(),
            }],
        )
        .unwrap();
        let bundle = merged_bundle(&doc);
        assert_eq!(bundle.len(), 2);
        assert_eq!(bundle[0].target, extra.target);
        assert_eq!(bundle[1].target, ctm.target);
        assert!(doc.get("operation").is_none());
    }
}

#[cfg(test)]
mod release_script_tests {
    use super::*;
    use crate::common::forge::scripts::{CURRENT_UPGRADE_ENV_DIR, UPGRADE_V33_ENV_DIR};
    use clap::CommandFactory;

    #[test]
    fn prepare_defaults_to_current_release() {
        let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();
        assert_eq!(args.ctm_script_path, CURRENT_CTM_UPGRADE_SCRIPT_PATH);
        assert_eq!(args.core_script_path, CURRENT_CORE_UPGRADE_SCRIPT_PATH);
        assert_eq!(args.upgrade_input_path, CURRENT_UPGRADE_LOCAL_INPUT_PATH);
        let help = UpgradePrepareAllArgs::command()
            .render_long_help()
            .to_string();
        assert!(help.contains("--ctm-script-path"));
        assert!(help.contains("--upgrade-input-path"));
    }

    /// The Foundry full-flow upgrade test of the default edge (`UpgradeTest_Local`, the registry
    /// bootstrap) must run the scripts this command prepares with by default: its CTM and core test
    /// subclasses extend the default CTM and core scripts. A release that changes a default here fails
    /// this until that test is moved onto the new scripts too.
    #[test]
    fn prepare_defaults_match_the_foundry_full_flow_test() {
        let contract_name = |script_path: &str| -> String {
            let file = script_path.rsplit('/').next().unwrap();
            file.trim_end_matches(".s.sol").to_string()
        };
        let read = |relative: &str| {
            std::fs::read_to_string(crate::common::paths::path_from_root(relative)).unwrap()
        };
        let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();

        let local_test = read("l1-contracts/test/foundry/l1/integration/UpgradeTest_Local.t.sol");
        let ctm = contract_name(&args.ctm_script_path);
        assert!(
            local_test.contains(&format!(" is {ctm} {{")),
            "UpgradeTest_Local's CTM test subclass must extend the default CTM script {ctm}"
        );
        let core = contract_name(&args.core_script_path);
        assert!(
            local_test.contains(&format!(" is {core} {{")),
            "UpgradeTest_Local's core test subclass must extend the default core script {core}"
        );
    }

    /// The default scripts must be the current release's: `yarn new-release` moves them together with the
    /// upgrade-env dir, so a hand edit of one without the other would prepare a release with another
    /// release's scripts.
    #[test]
    fn release_specific_defaults_belong_to_the_current_release() {
        let current_minor = CURRENT_UPGRADE_ENV_DIR
            .split("/v0.")
            .nth(1)
            .and_then(|rest| rest.split('.').next())
            .unwrap();
        let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();
        for script in [&args.ctm_script_path, &args.core_script_path] {
            let script_minor = script
                .strip_prefix("deploy-scripts/upgrade/v")
                .and_then(|rest| rest.split('/').next());
            assert_eq!(
                script_minor,
                Some(current_minor),
                "{script} is not the current release's script"
            );
        }
    }

    /// `--upgrade-env-dir` selects the env's input as well as its salts and output dir, so a prepare never mixes
    /// one release's input with another's salts.
    #[test]
    fn upgrade_env_dir_selects_the_per_env_input() {
        let historical = UpgradePrepareAllArgs::try_parse_from([
            "prepare",
            "--env",
            "stage",
            "--upgrade-env-dir",
            UPGRADE_V33_ENV_DIR.trim_start_matches('/'),
        ])
        .unwrap();
        let cfg = prepare_env_config(&historical).unwrap().unwrap();
        assert_eq!(
            per_env_upgrade_input(&cfg).unwrap(),
            format!("{UPGRADE_V33_ENV_DIR}/stage.toml")
        );

        let current = UpgradePrepareAllArgs::try_parse_from(["prepare", "--env", "stage"]).unwrap();
        let cfg = prepare_env_config(&current).unwrap().unwrap();
        assert_eq!(
            per_env_upgrade_input(&cfg).unwrap(),
            format!("{CURRENT_UPGRADE_ENV_DIR}/stage.toml")
        );
    }

    /// `--upgrade-env-dir` is the only release selector: an explicit `--upgrade-input-path` from another
    /// release's dir is rejected rather than mixed with the selected release's salts; one inside it is accepted.
    #[test]
    fn explicit_input_must_sit_in_the_selected_release_dir() {
        let mixed = UpgradePrepareAllArgs::try_parse_from([
            "prepare",
            "--env",
            "stage",
            "--upgrade-input-path",
            &format!("{UPGRADE_V33_ENV_DIR}/stage.toml"),
        ])
        .unwrap();
        assert!(prepare_env_config(&mixed).is_err());

        let consistent = UpgradePrepareAllArgs::try_parse_from([
            "prepare",
            "--env",
            "stage",
            "--upgrade-env-dir",
            UPGRADE_V33_ENV_DIR.trim_start_matches('/'),
            "--upgrade-input-path",
            &format!("{UPGRADE_V33_ENV_DIR}/stage.toml"),
        ])
        .unwrap();
        let cfg = prepare_env_config(&consistent).unwrap().unwrap();
        assert!(cfg.create2_factory_salt_for_upgrade().unwrap().is_some());
        assert!(cfg
            .protocol_ops_out_dir()
            .ends_with("upgrade-envs/v0.33.0-atomic-interop/output/stage"));
    }
}
