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
//!                         (`[governance_calls] calls`) on an anvil fork, holds a
//!                         registry package's fork state against what it must
//!                         leave, and emits one Safe bundle (governance owner
//!                         signs). Accepts multiple `--governance-toml` args and
//!                         replays their bundles in the order given.

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
use crate::upgrade_verification::registry::applied;
use crate::upgrade_verification::registry::package::RegistryPackage;
use crate::upgrade_verification::report::VerificationResult;

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
        // (the merger's appends, core, the derived executor legs, the CTM),
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
    /// The domain executors' governance entrypoints — the executor legs a registry-driven package
    /// carries. Each is a function of an (executor, object) pair the prepares report, so the merge
    /// DERIVES them rather than reading them from a prepare bundle. `zkstack-out` does not export
    /// the executors, so only these entrypoints are mirrored.
    interface IUpgradeExecutorEntrypoints {
        function applyL1Upgrade(address _coreTransition);
        function applyInfrastructureUpgrade(address _infrastructureTransition);
        function applyCTMUpgrade(address _transition);
    }
}

/// The provenance invariant of one prepare output: the governance bundle IS the
/// `external_actions` the script declared for the governance phase, in declaration order — same
/// target, same value, same calldata, one for one (`ExternalActionsLib.callsForPhase` emits it from
/// the same ledger). A script that composes a call it never declared fails the merge instead of
/// shipping it; so does one that declares an action it then omits, or emits the declared ones in
/// another order. The executor legs are not in any prepare's bundle: the merge derives them from
/// the objects the prepares report.
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
    let mut order = Vec::with_capacity(calls.len());
    for call in &calls {
        let matched = for_phase
            .iter()
            .enumerate()
            .position(|(i, action)| !claimed[i] && action.is_call(call));
        match matched {
            Some(i) => {
                claimed[i] = true;
                order.push(i);
            }
            None => anyhow::bail!(
                "{source}: the governance bundle carries a call no declared external action \
                 accounts for — target {:#x}, value {}, selector 0x{}. Every emitted call must be \
                 a declared action (see ExternalActionsLib); the executor legs are derived by the \
                 merge from the objects the prepares report",
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
    // The verifier holds the merged bundle's external actions to their declared order, so a
    // prepare that emits them in another one is refused here rather than there.
    anyhow::ensure!(
        order.windows(2).all(|pair| pair[0] < pair[1]),
        "{source}: emits its declared governance external actions in another order than it \
         declares them"
    );
    Ok(())
}

/// The objects a prepare reported in its `[registry]` summary, nonzero only.
fn registry_object(body: &toml::value::Table, key: &str) -> anyhow::Result<Option<Address>> {
    let Some(value) = body.get("registry").and_then(|registry| registry.get(key)) else {
        return Ok(None);
    };
    let raw = value
        .as_str()
        .with_context(|| format!("[registry] {key} must be an address string"))?;
    let address: Address = raw
        .parse()
        .with_context(|| format!("[registry] {key} = {raw:?} is not an address"))?;
    Ok((!address.is_zero()).then_some(address))
}

/// One derived executor leg, in canonical order (`LegKind`'s order in the verifier).
fn executor_leg(
    executor: Address,
    data: Vec<u8>,
) -> crate::common::governance_calls::GovernanceCall {
    crate::common::governance_calls::GovernanceCall {
        target: executor,
        value: alloy::primitives::U256::ZERO,
        data,
    }
}

/// The executor legs the merged bundle carries, DERIVED from the prepare summaries in canonical
/// order — core, then CTM infrastructure, then the CTM transition — each only when its object is
/// nonzero, all with no value:
///
/// 1. `CoreUpgradeExecutor.applyL1Upgrade(core_transition_addr)` on `core_upgrade_executor_addr`;
/// 2. `CTMUpgradeExecutor.applyInfrastructureUpgrade(ctm_infrastructure_transition_addr)` on
///    `ctm_upgrade_executor_addr`;
/// 3. `CTMUpgradeExecutor.applyCTMUpgrade(ctm_transition_addr)` on `ctm_upgrade_executor_addr`.
///
/// A bootstrap edge (`bootstrap_migration_addr` nonzero) and a transition replacement
/// (`replacement_transition_addr` nonzero) derive none: the bootstrap's core transition rides its
/// own derived sequence, and a replacement is one declared `forward`. Either one reporting an
/// object only a leg would apply is refused, as is a leg whose executor is missing or zero and a
/// package that is none of the three kinds yet derives no leg.
fn derive_executor_legs(
    core: &toml::value::Table,
    ctms: &[(Address, &toml::value::Table)],
) -> anyhow::Result<Vec<crate::common::governance_calls::GovernanceCall>> {
    let core_transition = registry_object(core, "core_transition_addr").context("core prepare")?;
    let core_executor =
        registry_object(core, "core_upgrade_executor_addr").context("core prepare")?;

    let mut infrastructure = None;
    let mut transition = None;
    let mut ctm_executor = None;
    let mut bootstrap = None;
    let mut replacement = None;
    for (proxy, body) in ctms {
        let read = |key: &str| {
            registry_object(body, key).with_context(|| format!("CTM prepare {proxy:#x}"))
        };
        for (slot, key) in [
            (&mut infrastructure, "ctm_infrastructure_transition_addr"),
            (&mut transition, "ctm_transition_addr"),
            (&mut ctm_executor, "ctm_upgrade_executor_addr"),
            (&mut bootstrap, "bootstrap_migration_addr"),
            (&mut replacement, "replacement_transition_addr"),
        ] {
            if let Some(address) = read(key)? {
                anyhow::ensure!(
                    slot.is_none(),
                    "two CTM prepares report a {key}; one upgrade drives exactly one CTM"
                );
                *slot = Some(address);
            }
        }
    }

    if let Some(migration) = bootstrap {
        anyhow::ensure!(
            replacement.is_none(),
            "the CTM prepare reports both a bootstrap migration ({migration:#x}) and a \
             replacement transition: one package is one kind"
        );
        for (key, object) in [
            ("ctm_infrastructure_transition_addr", infrastructure),
            ("ctm_transition_addr", transition),
        ] {
            if let Some(object) = object {
                anyhow::bail!(
                    "the bootstrap edge {migration:#x} derives no executor leg, but its CTM \
                     prepare reports {key} {object:#x}, which nothing in the edge would apply"
                );
            }
        }
        return Ok(Vec::new());
    }
    if let Some(replacement) = replacement {
        for (key, object) in [
            ("core_transition_addr", core_transition),
            ("ctm_infrastructure_transition_addr", infrastructure),
        ] {
            if let Some(object) = object {
                anyhow::bail!(
                    "the transition replacement {replacement:#x} carries no executor leg, but \
                     the package reports {key} {object:#x}, which nothing in it would apply"
                );
            }
        }
        return Ok(Vec::new());
    }

    let require_executor = |executor: Option<Address>, key: &str, object: Address| {
        executor.with_context(|| {
            format!(
                "the prepares report {object:#x} for an executor leg but no {key} (missing or \
                 zero) to send it to"
            )
        })
    };
    let mut legs = Vec::new();
    if let Some(object) = core_transition {
        let executor = require_executor(core_executor, "core_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyL1UpgradeCall {
                _coreTransition: object,
            }
            .abi_encode(),
        ));
    }
    if let Some(object) = infrastructure {
        let executor = require_executor(ctm_executor, "ctm_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyInfrastructureUpgradeCall {
                _infrastructureTransition: object,
            }
            .abi_encode(),
        ));
    }
    if let Some(object) = transition {
        let executor = require_executor(ctm_executor, "ctm_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyCTMUpgradeCall {
                _transition: object,
            }
            .abi_encode(),
        ));
    }
    anyhow::ensure!(
        !legs.is_empty(),
        "the prepares report no core transition, no CTM infrastructure transition and no CTM \
         transition, and the package is neither a bootstrap edge nor a transition replacement: \
         it upgrades nothing"
    );
    Ok(legs)
}

/// Replay the governance bundle of one or more prepared TOMLs, in the order given.
///
/// Each TOML's `[governance_calls] calls` is one `governanceExecuteCalls` (legacy Governance) or
/// `governanceExecuteCallsDirect` (PUH) invocation signed by `sender` (the governance owner), so
/// they merge into one governance Safe bundle. A bootstrap bundle's last call is
/// `RegistryBootstrapMigration.validateApplied()`, so an incomplete edge reverts the replay
/// itself. Right after a registry package's bundle runs, the fork is also held against the whole
/// state it must have left ([`expect_applied`]), so a bundle that executes without landing fails
/// the command here.
/// Returns the resolved governance contract address for diagnostics.
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
        expect_applied(&runner.rpc_url, toml_path, governance_addr)
            .await
            .with_context(|| format!("governance bundle ({})", toml_path.display()))?;
    }
    Ok(governance_addr)
}

/// When `governance_toml` is a registry package, holds the fork state after its bundle against
/// everything the package must have left ([`applied::verify_applied`]); any unmet expectation
/// fails. A TOML that is not a registry package is left alone.
async fn expect_applied(
    rpc_url: &str,
    governance_toml: &Path,
    governance: Address,
) -> anyhow::Result<()> {
    let Some(package) = RegistryPackage::load_if_registry(governance_toml)? else {
        logger::info(format!(
            "{} is not a registry package: no post-state to check",
            governance_toml.display()
        ));
        return Ok(());
    };
    logger::step("Checking the state the bundle left");
    let provider = crate::common::ethereum::get_provider(rpc_url)?;
    let mut result = VerificationResult::default();
    applied::verify_applied(&provider, &package, governance, &mut result).await;
    result
        .ensure_success()
        .context("the replayed bundle executed but did not leave the state its package describes")
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

    /// The ZK token asset id the release's genesis force deployments pin, in place of the env's
    /// `zk_token_asset_id` (or the local network's without `--env`). Only for an ecosystem the
    /// env file does not describe — a harness's scratch L1, whose live release must keep its own.
    #[clap(long)]
    pub zk_token_asset_id: Option<B256>,
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
    // here covers every script in the pipeline.
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
    let zk_token_asset_id = match (args.zk_token_asset_id, env_cfg.as_ref()) {
        (Some(zk_token_asset_id), _) => zk_token_asset_id,
        (None, Some(cfg)) => cfg.require_zk_token_asset_id()?,
        (None, None) => {
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
    // the whole governance set and fold its wiring call into the bundle. The
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

/// Merge the core + per-CTM prepare TOMLs, the derived executor legs and the merger's own extras
/// (the in-memory PUH/Guardians wiring and the CTM `acceptOwnership()` normalization) into a
/// single ecosystem TOML at `dst`.
///
/// The merger COMPOSES nothing. The one bundle is, in order: the extras (they must precede a
/// bootstrap's `ctm.transferOwnership(migration)`, which assumes governance already owns the
/// CTM), the core prepare's declared calls, the DERIVED executor legs ([`derive_executor_legs`]:
/// one contiguous run in canonical order, none for a bootstrap or a replacement), then the CTM
/// prepare's declared calls. Every call other than a leg is declared in `external_actions` with
/// phase `governance`; a prepare bundle carrying a call the artifact does not name fails the
/// merge (`check_bundle_provenance`). The legs need no summary table of their own: the verifier
/// recovers them from the calldata and reconciles them with `[core.registry]` and
/// `[ctms.*.registry]`. Shape:
///
/// ```toml
/// [[external_actions]]            # every governance/admin call that is NOT an executor leg,
/// phase = "governance"            # carrying the call itself (see `common::external_actions`)
/// label = "…"
/// authority = "…"
/// target = "0x…"
/// value = "0"
/// data = "0x…"
///
/// [governance_calls]              # the one bundle: extras, core actions, the DERIVED legs,
/// calls = "0x..."                 # CTM actions
///
/// [test_upgrade_calls]            # the CTM prepare's simulator probes, when it wrote any
/// test_create_chain_zkos = "0x..."
/// test_create_chain_zkos_caller = "0x..."
/// test_upgrade_chain_zkos = "0x..."
/// test_upgrade_chain_zkos_caller = "0x..."
///
/// [core]                          # whole core TOML minus its [governance_calls]; its
/// ...                             # [registry] names the core leg's object and executor
///
/// [ctms.zksync_os]                # whole CTM TOML minus its [governance_calls] and probes;
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
    let mut ctm_outputs = Vec::with_capacity(ctm_entries.len());
    for entry in ctm_entries {
        ctm_outputs.push((entry.proxy, load_prepare_output(&entry.toml)?));
    }
    let mut doc = merge_prepare_outputs(load_prepare_output(core_toml)?, ctm_outputs, extras)?;
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
        doc.insert("zk_governance".into(), Value::Table(table));
    }

    let body = format!(
        "# Auto-generated by `protocol-ops ecosystem upgrade-prepare-all`.\n\
         # Merged ecosystem upgrade artifact: top-level [governance_calls] calls is\n\
         # the one governance bundle of {} prepare TOML(s) — the merger's extras,\n\
         # the core prepare's calls, the derived executor legs (applyL1Upgrade ->\n\
         # applyInfrastructureUpgrade -> applyCTMUpgrade) and the CTM prepare's calls,\n\
         # never composed here; `external_actions` names every call in it that is\n\
         # not an executor leg.\n\
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

/// A ZKsync OS CTM's probes under the simulator's tags: `test_<probe>` becomes `test_<probe>_zkos`
/// and its `test_<probe>_caller` becomes `test_<probe>_zkos_caller`.
fn zksync_os_probe_tags(probes: toml::value::Table) -> toml::value::Table {
    probes
        .into_iter()
        .map(|(key, value)| {
            let tag = match key.strip_suffix("_caller") {
                Some(probe) => format!("{probe}_zkos_caller"),
                None => format!("{key}_zkos"),
            };
            (tag, value)
        })
        .collect()
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

/// The merged document of [`write_merged_ecosystem_toml`] minus `[zk_governance]`:
/// `external_actions`, `[governance_calls]`, the optional `[test_upgrade_calls]`, `[core]`,
/// `[ctms.*]` and `[misc]`. `toml::to_string` writes the keys in alphabetical order.
fn merge_prepare_outputs(
    core: PrepareOutputParts,
    ctms: Vec<(Address, PrepareOutputParts)>,
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
    let legs = derive_executor_legs(
        &core_body,
        &ctms
            .iter()
            .map(|(proxy, ctm)| (*proxy, &ctm.body))
            .collect::<Vec<_>>(),
    )?;
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

    // The derived legs sit after the core prepare's declared actions and before the CTM's.
    chunks.push(format!("0x{}", hex::encode(encode_calls(&legs))));

    // `UpgradeInner::prepare` rejects any non-ZKsync-OS CTM, so every CTM that
    // reaches the merge is ZKsync OS. The merge keys per-CTM sections by the fixed
    // `zksync_os` label, so two CTMs in one upgrade collide here.
    let mut ctms_table = Table::new();
    let mut test_upgrade_calls: Option<Table> = None;
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
        let mut body = ctm.body;
        // The simulator reads the probes at the top level only, under ZKsync OS tags.
        test_upgrade_calls = match body.remove("test_upgrade_calls") {
            Some(Value::Table(probes)) => Some(zksync_os_probe_tags(probes)),
            Some(other) => anyhow::bail!(
                "[test_upgrade_calls] in CTM prepare {proxy:#x} must be a table (got {})",
                other.type_str()
            ),
            None => None,
        };
        ctms_table.insert(label.to_string(), Value::Table(body));
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
    if let Some(probes) = test_upgrade_calls {
        doc.insert("test_upgrade_calls".into(), Value::Table(probes));
    }
    doc.insert("core".into(), Value::Table(core_body));
    doc.insert("ctms".into(), Value::Table(ctms_table));
    if let Some(body) = misc_body {
        doc.insert("misc".into(), Value::Table(body));
    }
    Ok(doc)
}

/// Read the `acceptOwnership()` Call list written by
/// `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
/// (in `<l1-contracts>/script-out/pre-governance-accept-ownerships.toml`):
/// one per CTM, and one per CTM ValidatorTimelock, whose `pendingOwner` is
/// governance after the prepare pre-step.
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
/// set and fold its wiring call into the governance bundle. `redeploy_declared` is the release's
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

// ─── forge-script upgrades ───────────────────────────────────────────────────────

/// Prepare a `forge-script` upgrade (see `upgrade_descriptor`): run its entry point on
/// `l1_rpc_url` as `deployer` and write the deployer's transactions as Safe bundles plus
/// `manifest.json` under `out` — the packaging `upgrade-prepare-all` uses, so the deploy
/// bundle, its replay and its broadcast are shared with the `prepare-all` flow.
///
/// The script runs as a dry run: forge records the transactions without sending them, so
/// the fork stays at its pre-upgrade state and the caller can replay the packed bundle on it.
pub async fn run_forge_script_prepare(
    upgrade_name: &str,
    upgrade: &crate::common::upgrade_descriptor::ForgeScriptUpgrade,
    env: &str,
    l1_rpc_url: &str,
    deployer: Address,
    out: &Path,
) -> anyhow::Result<()> {
    let shared = crate::common::SharedRunArgs {
        l1_rpc_url: l1_rpc_url.to_string(),
        out: Some(out.to_path_buf()),
        subdir: None,
        forge_args: Default::default(),
    };
    let mut runner = ForgeRunner::new(&shared)?;
    let wallet = runner.prepare_sender(deployer).await?;
    let script = runner
        .script_path_from_root(
            &crate::common::paths::resolve_l1_contracts_path()?,
            upgrade.script_path(),
        )
        .with_calldata(&Bytes::from(upgrade.calldata(env)?))
        .with_ffi()
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(&wallet);
    logger::step(format!("Running {} for {env} (dry run)", upgrade.script));
    runner
        .run(script)
        .with_context(|| format!("failed to execute {}", upgrade.script))?;
    crate::common::output::write_output_if_requested(
        &format!("ecosystem.prepare.{upgrade_name}"),
        &shared,
        &runner,
        &serde_json::json!({
            "upgrade": upgrade_name,
            "env": env,
            "script": upgrade.script,
            "signature": upgrade.signature,
            "args": upgrade.args_for(env),
        }),
        &serde_json::json!({}),
    )
    .await
}

/// Run a `forge-script` upgrade's `[execution]` script for `env` on `l1_rpc_url` (read-only: a
/// simulation without a sender), which writes `output/<env>/<execution.output>`.
pub fn run_execution_script(
    execution: &crate::common::upgrade_descriptor::ExecutionScript,
    env: &str,
    l1_rpc_url: &str,
) -> anyhow::Result<()> {
    let shared = crate::common::SharedRunArgs {
        l1_rpc_url: l1_rpc_url.to_string(),
        out: None,
        subdir: None,
        forge_args: Default::default(),
    };
    let mut runner = ForgeRunner::new(&shared)?;
    let script = runner
        .script_path_from_root(
            &crate::common::paths::resolve_l1_contracts_path()?,
            execution.script_path(),
        )
        .with_calldata(&Bytes::from(execution.calldata(env)?))
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT);
    logger::step(format!(
        "Running {} for {env} (read-only)",
        execution.script
    ));
    runner
        .run(script)
        .with_context(|| format!("failed to execute {}", execution.script))
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

    /// A prepare that emits its declared actions in another order than it declares them fails:
    /// the verifier holds the merged bundle's external actions to their declared order.
    #[test]
    fn a_bundle_out_of_its_declared_order_fails() {
        let (first, second) = (call(0x11, &[0xaa]), call(0x22, &[0xbb]));
        let declared = vec![
            ExternalAction::governance("l", "a", &first),
            ExternalAction::governance("l", "a", &second),
        ];
        let err = check_bundle_provenance("t", &gov(&[second, first]), &declared)
            .expect_err("a reordered bundle must fail");
        assert!(err.to_string().contains("another order"), "{err}");
    }

    const CORE_EXECUTOR: Address = Address::repeat_byte(0xe0);
    const CTM_EXECUTOR: Address = Address::repeat_byte(0xe7);
    const CORE_TRANSITION: Address = Address::repeat_byte(0xee);
    const INFRASTRUCTURE: Address = Address::repeat_byte(0x1f);
    const TRANSITION: Address = Address::repeat_byte(0xcc);

    /// The encoding of one leg, transcribed independently of the `sol!` block the merge uses:
    /// the selector from the executors' compiled `methodIdentifiers`, then the object word.
    fn transcribed_leg(executor: Address, selector: [u8; 4], object: Address) -> GovernanceCall {
        let mut data = selector.to_vec();
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(object.as_slice());
        GovernanceCall {
            target: executor,
            value: alloy::primitives::U256::ZERO,
            data,
        }
    }

    fn core_leg() -> GovernanceCall {
        transcribed_leg(CORE_EXECUTOR, [0x60, 0x93, 0xa2, 0x59], CORE_TRANSITION)
    }

    fn infrastructure_leg() -> GovernanceCall {
        transcribed_leg(CTM_EXECUTOR, [0x68, 0xe9, 0x89, 0x78], INFRASTRUCTURE)
    }

    fn transition_leg() -> GovernanceCall {
        transcribed_leg(CTM_EXECUTOR, [0x7b, 0x1b, 0x71, 0x6a], TRANSITION)
    }

    /// The transcribed selectors are the entrypoints' real ones.
    #[test]
    fn the_transcribed_selectors_are_the_executor_entrypoints() {
        for (leg, signature) in [
            (core_leg(), "applyL1Upgrade(address)"),
            (infrastructure_leg(), "applyInfrastructureUpgrade(address)"),
            (transition_leg(), "applyCTMUpgrade(address)"),
        ] {
            assert_eq!(
                &leg.data[..4],
                &alloy::primitives::keccak256(signature.as_bytes())[..4],
                "{signature}"
            );
        }
    }

    fn address_value(address: Address) -> toml::Value {
        toml::Value::String(format!("{address:#x}"))
    }

    /// A prepare body whose `[registry]` reports `entries`.
    fn registry_body(entries: &[(&str, Address)]) -> toml::value::Table {
        let mut registry = toml::value::Table::new();
        for (key, address) in entries {
            registry.insert(key.to_string(), address_value(*address));
        }
        let mut body = toml::value::Table::new();
        body.insert("registry".into(), toml::Value::Table(registry));
        body
    }

    /// The core prepare's summary: its executor always, its transition when it deployed one.
    fn core_body(transition: Option<Address>) -> toml::value::Table {
        registry_body(&[
            ("core_transition_addr", transition.unwrap_or(Address::ZERO)),
            ("core_upgrade_executor_addr", CORE_EXECUTOR),
        ])
    }

    /// The CTM prepare's summary, every object zero unless set.
    fn ctm_body(entries: &[(&str, Address)]) -> toml::value::Table {
        let mut all: Vec<(&str, Address)> = vec![
            ("ctm_transition_addr", Address::ZERO),
            ("ctm_infrastructure_transition_addr", Address::ZERO),
            ("bootstrap_migration_addr", Address::ZERO),
            ("ctm_upgrade_executor_addr", CTM_EXECUTOR),
        ];
        for (key, address) in entries {
            match all.iter_mut().find(|(k, _)| k == key) {
                Some(entry) => entry.1 = *address,
                None => all.push((key, *address)),
            }
        }
        registry_body(&all)
    }

    fn derive(
        core: toml::value::Table,
        ctm: Option<toml::value::Table>,
    ) -> anyhow::Result<Vec<GovernanceCall>> {
        let ctms: Vec<(Address, toml::value::Table)> = ctm
            .into_iter()
            .map(|body| (Address::repeat_byte(0x77), body))
            .collect();
        derive_executor_legs(
            &core,
            &ctms
                .iter()
                .map(|(proxy, body)| (*proxy, body))
                .collect::<Vec<_>>(),
        )
    }

    fn targets_and_data(calls: &[GovernanceCall]) -> Vec<(Address, Vec<u8>)> {
        calls.iter().map(|c| (c.target, c.data.clone())).collect()
    }

    /// All three legs, in canonical order: core, CTM infrastructure, CTM transition — each sent
    /// to its domain's executor with no value.
    #[test]
    fn all_three_legs_derive_in_canonical_order() {
        let legs = derive(
            core_body(Some(CORE_TRANSITION)),
            Some(ctm_body(&[
                ("ctm_transition_addr", TRANSITION),
                ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
            ])),
        )
        .unwrap();
        assert_eq!(
            targets_and_data(&legs),
            targets_and_data(&[core_leg(), infrastructure_leg(), transition_leg()])
        );
        assert!(legs.iter().all(|leg| leg.value.is_zero()));
    }

    /// Each leg alone — a core-only package needing no CTM prepare at all.
    #[test]
    fn each_leg_derives_alone() {
        let core_only = derive(core_body(Some(CORE_TRANSITION)), None).unwrap();
        assert_eq!(
            targets_and_data(&core_only),
            targets_and_data(&[core_leg()])
        );

        let infrastructure_only = derive(
            core_body(None),
            Some(ctm_body(&[(
                "ctm_infrastructure_transition_addr",
                INFRASTRUCTURE,
            )])),
        )
        .unwrap();
        assert_eq!(
            targets_and_data(&infrastructure_only),
            targets_and_data(&[infrastructure_leg()])
        );

        let transition_only = derive(
            core_body(None),
            Some(ctm_body(&[("ctm_transition_addr", TRANSITION)])),
        )
        .unwrap();
        assert_eq!(
            targets_and_data(&transition_only),
            targets_and_data(&[transition_leg()])
        );
    }

    /// A bootstrap edge derives no leg: its core transition rides the bootstrap's own sequence.
    #[test]
    fn a_bootstrap_derives_no_leg() {
        let legs = derive(
            core_body(Some(CORE_TRANSITION)),
            Some(ctm_body(&[(
                "bootstrap_migration_addr",
                Address::repeat_byte(0x55),
            )])),
        )
        .unwrap();
        assert!(legs.is_empty());
    }

    /// A bootstrap reporting a CTM-domain object would ship an object nothing applies.
    #[test]
    fn a_bootstrap_with_a_ctm_object_is_refused() {
        for key in ["ctm_transition_addr", "ctm_infrastructure_transition_addr"] {
            let err = derive(
                core_body(None),
                Some(ctm_body(&[
                    ("bootstrap_migration_addr", Address::repeat_byte(0x55)),
                    (key, TRANSITION),
                ])),
            )
            .unwrap_err();
            assert!(err.to_string().contains("derives no executor leg"), "{err}");
            assert!(err.to_string().contains(key), "{err}");
        }
    }

    /// A replacement derives no leg: its `ctm_transition_addr` is the replacement, which its one
    /// declared `forward` installs.
    #[test]
    fn a_replacement_derives_no_leg() {
        let legs = derive(
            core_body(None),
            Some(ctm_body(&[
                ("ctm_transition_addr", TRANSITION),
                ("replacement_transition_addr", TRANSITION),
            ])),
        )
        .unwrap();
        assert!(legs.is_empty());
    }

    /// A core transition (or an infrastructure object) prepared beside a replacement is refused.
    #[test]
    fn a_core_transition_on_a_replacement_is_refused() {
        let err = derive(
            core_body(Some(CORE_TRANSITION)),
            Some(ctm_body(&[
                ("ctm_transition_addr", TRANSITION),
                ("replacement_transition_addr", TRANSITION),
            ])),
        )
        .unwrap_err();
        assert!(err.to_string().contains("core_transition_addr"), "{err}");
        assert!(err.to_string().contains("carries no executor leg"), "{err}");

        let err = derive(
            core_body(None),
            Some(ctm_body(&[
                ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
                ("replacement_transition_addr", TRANSITION),
            ])),
        )
        .unwrap_err();
        assert!(
            err.to_string()
                .contains("ctm_infrastructure_transition_addr"),
            "{err}"
        );
    }

    #[test]
    fn a_bootstrap_beside_a_replacement_is_refused() {
        let err = derive(
            core_body(None),
            Some(ctm_body(&[
                ("bootstrap_migration_addr", Address::repeat_byte(0x55)),
                ("replacement_transition_addr", TRANSITION),
            ])),
        )
        .unwrap_err();
        assert!(err.to_string().contains("one package is one kind"), "{err}");
    }

    /// A leg whose executor is missing or zero has nowhere to be sent.
    #[test]
    fn a_leg_without_its_executor_is_refused() {
        let mut core = core_body(Some(CORE_TRANSITION));
        core.get_mut("registry")
            .unwrap()
            .as_table_mut()
            .unwrap()
            .remove("core_upgrade_executor_addr");
        let err = derive(core, None).unwrap_err();
        assert!(
            err.to_string().contains("core_upgrade_executor_addr"),
            "{err}"
        );

        let err = derive(
            core_body(None),
            Some(ctm_body(&[
                ("ctm_transition_addr", TRANSITION),
                ("ctm_upgrade_executor_addr", Address::ZERO),
            ])),
        )
        .unwrap_err();
        assert!(
            err.to_string().contains("ctm_upgrade_executor_addr"),
            "{err}"
        );
    }

    /// Neither a bootstrap nor a replacement, and no object to apply: it upgrades nothing.
    #[test]
    fn a_package_with_no_leg_is_refused() {
        let err = derive(core_body(None), Some(ctm_body(&[]))).unwrap_err();
        assert!(err.to_string().contains("upgrades nothing"), "{err}");
        let err = derive(core_body(None), None).unwrap_err();
        assert!(err.to_string().contains("upgrades nothing"), "{err}");
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

    fn prepare_output(body: toml::value::Table, calls: &[GovernanceCall]) -> PrepareOutputParts {
        PrepareOutputParts {
            body,
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
    /// core prepare's calls, the derived legs as one contiguous run, then the CTM prepare's calls.
    /// Every call but the legs is declared, the extras included, and no summary table is added.
    #[test]
    fn the_merged_bundle_runs_extras_core_legs_then_ctm() {
        let extra = call(0xe1, &[0x01]);
        let core = call(0xc1, &[0x02]);
        let ctm = call(0xd1, &[0x03]);
        let doc = merge_prepare_outputs(
            prepare_output(
                core_body(Some(CORE_TRANSITION)),
                std::slice::from_ref(&core),
            ),
            vec![(
                Address::repeat_byte(0x77),
                prepare_output(
                    ctm_body(&[
                        ("ctm_transition_addr", TRANSITION),
                        ("ctm_infrastructure_transition_addr", INFRASTRUCTURE),
                    ]),
                    std::slice::from_ref(&ctm),
                ),
            )],
            &[ExtraGovernanceCall {
                label: "extra",
                authority: "protocol governance",
                call: extra.clone(),
            }],
        )
        .unwrap();

        let bundle = merged_bundle(&doc);
        assert_eq!(
            targets_and_data(&bundle),
            targets_and_data(&[
                extra,
                core,
                core_leg(),
                infrastructure_leg(),
                transition_leg(),
                ctm
            ])
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
            assert_eq!(is_declared, !(2..5).contains(&i), "call {i}");
        }
        assert!(doc.get("operation").is_none());
    }

    /// The merged bundle is exactly what the verifier's loader classifies as an upgrade, with the
    /// legs it recovers reconciling against the summaries the merge carried over.
    #[test]
    fn the_merged_package_loads_as_an_upgrade() {
        let core = core_body(Some(CORE_TRANSITION));
        let mut ctm = ctm_body(&[("ctm_transition_addr", TRANSITION)]);
        let mut state_transition = toml::value::Table::new();
        state_transition.insert(
            "chain_type_manager_proxy".into(),
            address_value(Address::repeat_byte(0x77)),
        );
        ctm.insert(
            "state_transition".into(),
            toml::Value::Table(state_transition),
        );
        let doc = merge_prepare_outputs(
            prepare_output(core, &[]),
            vec![(Address::repeat_byte(0x77), prepare_output(ctm, &[]))],
            &[],
        )
        .unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ecosystem.toml");
        fs::write(&path, toml::to_string(&doc).unwrap()).unwrap();
        let RegistryPackage::Upgrade(package) = RegistryPackage::load(&path).unwrap() else {
            panic!("a merged package with legs must load as an upgrade");
        };
        assert_eq!(package.legs.len(), 2);
        assert_eq!(package.legs[0].object, CORE_TRANSITION);
        assert_eq!(package.legs[1].object, TRANSITION);
    }

    /// After a replay, a governance TOML that is no registry package has no post-state to check
    /// and reads nothing; a registry package is held against the fork, so one whose state cannot
    /// be read fails the command.
    #[tokio::test]
    async fn the_post_replay_check_holds_only_registry_packages() {
        const UNREACHABLE: &str = "http://127.0.0.1:1";
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("plain.toml");
        fs::write(
            &plain,
            format!(
                "[governance_calls]\ncalls = \"{}\"\n",
                bundle_hex(&[call(0x51, &[0x04])])
            ),
        )
        .unwrap();
        expect_applied(UNREACHABLE, &plain, Address::ZERO)
            .await
            .expect("a TOML that is no registry package is not read back");

        let doc = merge_prepare_outputs(
            prepare_output(core_body(Some(CORE_TRANSITION)), &[]),
            Vec::new(),
            &[],
        )
        .unwrap();
        let package = dir.path().join("ecosystem.toml");
        fs::write(&package, toml::to_string(&doc).unwrap()).unwrap();
        let err = expect_applied(UNREACHABLE, &package, Address::ZERO)
            .await
            .expect_err("an unreadable post-state is not a landed one");
        assert!(
            format!("{err:#}").contains("did not leave the state its package describes"),
            "{err:#}"
        );
    }

    /// The CTM prepare's probes reach the simulator: the merge lifts them out of
    /// `[ctms.zksync_os]`, where the simulator does not look, to the top level under ZKsync OS tags.
    #[test]
    fn the_ctm_prepare_probes_reach_the_simulator() {
        // The bundle is the one derived transition leg: one simulator transaction.
        let mut ctm = prepare_output(ctm_body(&[("ctm_transition_addr", TRANSITION)]), &[]);
        let mut probes = toml::value::Table::new();
        for probe in ["test_create_chain", "test_upgrade_chain"] {
            probes.insert(probe.into(), bundle_hex(&[call(0x51, &[0x04])]).into());
            probes.insert(
                format!("{probe}_caller"),
                format!("{:#x}", Address::repeat_byte(0xad)).into(),
            );
        }
        ctm.body
            .insert("test_upgrade_calls".into(), toml::Value::Table(probes));
        let doc = merge_prepare_outputs(
            prepare_output(core_body(None), &[]),
            vec![(Address::repeat_byte(0x77), ctm)],
            &[],
        )
        .unwrap();
        assert!(doc["ctms"]["zksync_os"].get("test_upgrade_calls").is_none());

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ecosystem.toml");
        fs::write(&path, toml::to_string(&doc).unwrap()).unwrap();
        assert_eq!(
            crate::commands::ecosystem::simulator::simulator_transaction_tags(&path).unwrap(),
            [
                "governance",
                "test_create_chain_zkos",
                "test_upgrade_chain_zkos"
            ]
        );
    }

    /// A bootstrap merge derives no leg, so the bundle is the extras followed by the prepares'
    /// declared calls.
    #[test]
    fn a_bootstrap_merge_derives_no_executor_leg() {
        let extra = call(0xe1, &[0x01]);
        let ctm = call(0xd1, &[0x03]);
        let doc = merge_prepare_outputs(
            prepare_output(core_body(Some(CORE_TRANSITION)), &[]),
            vec![(
                Address::repeat_byte(0x77),
                prepare_output(
                    ctm_body(&[("bootstrap_migration_addr", Address::repeat_byte(0x55))]),
                    std::slice::from_ref(&ctm),
                ),
            )],
            &[ExtraGovernanceCall {
                label: "extra",
                authority: "protocol governance",
                call: extra.clone(),
            }],
        )
        .unwrap();
        let bundle = merged_bundle(&doc);
        assert_eq!(targets_and_data(&bundle), targets_and_data(&[extra, ctm]));
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
    /// bootstrap) must run the scripts this command prepares with by default: its CTM test subclass
    /// extends the default CTM script, and it runs the default core script (or a subclass). A
    /// release that changes a default here fails this until that test is moved onto the new
    /// scripts too.
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
            local_test.contains(&format!(" is {core} {{"))
                || local_test.contains(&format!("new {core}()")),
            "UpgradeTest_Local must run the default core script {core}, itself or a test subclass of it"
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
