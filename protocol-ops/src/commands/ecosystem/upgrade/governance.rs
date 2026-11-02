//! `ecosystem upgrade-governance`: replays the package's governance bundle on an anvil fork.

use std::fs;
use std::path::{Path, PathBuf};

use alloy::hex;
use alloy::primitives::{Address, Bytes};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::forge::scripts::ADMIN_FUNCTIONS_INVOCATION;
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
pub(super) struct UpgradeGovernanceOutput {
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
pub(super) struct EcosystemUpgradeOutput {
    governance_calls: GovernanceCallsTable,
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
pub(super) async fn expect_applied(
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

pub(super) fn read_governance_calls(governance_toml: &Path) -> anyhow::Result<String> {
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

pub(super) async fn governance_execute(
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
