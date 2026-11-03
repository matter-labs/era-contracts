//! `ecosystem upgrade-prepare-all` and the forge-script prepare.

use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::{Address, Bytes, B256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::ecosystem::upgrade_full::UpgradeFull;
use crate::commands::ecosystem::upgrade_inner::{CtmInputs, PrepareInputs, UpgradeInner};
use crate::common::env_config::EnvConfig;
use crate::common::forge::scripts::{current_release, CurrentRelease, UPGRADE_CORE_OUTPUT_PATH};
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::output::write_output_if_requested;
use crate::common::paths;
use crate::common::SharedRunArgs;

use super::*;

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

    /// Upgrade input TOML (relative to l1-contracts root). Defaults to the current release's
    /// `local.toml`, or with `--env` to the release dir's `<env>.toml`.
    #[clap(long)]
    pub upgrade_input_path: Option<String>,

    /// Override the core-prepare output TOML path (relative to l1-contracts
    /// root). Defaults to the canonical `script-out/upgrade-core.toml`.
    #[clap(long, default_value = UPGRADE_CORE_OUTPUT_PATH, hide = true)]
    pub core_output_path: String,

    /// Core upgrade script. Defaults to the current release's; historical releases must select their own
    /// script and input.
    #[clap(long)]
    pub core_script_path: Option<String>,

    /// CTM upgrade script. Defaults to the current release's; historical releases must select their own
    /// script and input.
    #[clap(long)]
    pub ctm_script_path: Option<String>,

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
pub(super) struct CtmConfigFile {
    #[serde(rename = "ctm", default)]
    ctms: Vec<CtmConfigEntry>,
}

#[derive(Debug, Deserialize)]
pub(super) struct CtmConfigEntry {
    proxy: Address,
    #[serde(default)]
    rollup_da_manager: Option<Address>,
}

#[derive(Serialize)]
pub(super) struct UpgradePrepareAllOutput {
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
pub(super) struct CtmGovernanceTomlEntry {
    ctm_proxy: String,
    governance_toml: String,
}

/// The `--env` preset for `upgrade-prepare-all`, from the release dir `--upgrade-env-dir` selects (the current
/// release's by default). That dir is the only release selector: an explicit `--upgrade-input-path` must sit in
/// it, so the input, the CREATE2 salts and the output dir always belong to the same release.
pub(super) fn prepare_env_config(
    args: &UpgradePrepareAllArgs,
) -> anyhow::Result<Option<EnvConfig>> {
    let Some(cfg) = args.topology.env_config()? else {
        return Ok(None);
    };
    if let Some(upgrade_input_path) = &args.upgrade_input_path {
        let input_dir = paths::resolve_l1_contracts_path()?
            .join(upgrade_input_path.trim_start_matches('/'))
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
            upgrade_input_path,
            env_dir.display(),
            cfg.env
        );
    }
    Ok(Some(cfg))
}

/// `explicit`, or the current release's value when it is unset (see [`current_release`]). The release is read
/// only then, so a historical edge that names its own input and scripts does not depend on it.
pub(super) fn or_current_release(
    explicit: &Option<String>,
    current: impl FnOnce(&CurrentRelease) -> String,
) -> anyhow::Result<String> {
    match explicit {
        Some(value) => Ok(value.clone()),
        None => Ok(current(current_release()?)),
    }
}

/// The env's upgrade input (`/<release dir>/<env>.toml`, relative to `l1-contracts/`) from the release dir
/// `cfg` was loaded from, so the input, the salts and the output dir belong to the same release.
///
/// Fails closed on a missing file rather than keeping the CLI default. The default is the *local* input, so a
/// silent fallback would hand a real environment local's values for the keys the input does supply —
/// the owner, for one. Failing here also catches a mistyped `--env`.
pub(super) fn per_env_upgrade_input(cfg: &EnvConfig) -> anyhow::Result<String> {
    let per_env_abs = &cfg.upgrade_input_path;
    anyhow::ensure!(
        per_env_abs.exists(),
        "no upgrade input for --env {} at {}. Add it — an empty file is fine if the environment needs \
         nothing from the input — because this command will not fall back to the local default, which \
         would silently give this environment local's owner and salts.",
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
        if args.upgrade_input_path.is_none() {
            let per_env_rel = per_env_upgrade_input(cfg)?;
            logger::info(format!("Using per-env upgrade input: {per_env_rel}"));
            args.upgrade_input_path = Some(per_env_rel);
        }
    }
    let upgrade_input_path =
        or_current_release(&args.upgrade_input_path, CurrentRelease::local_input_path)?;
    let core_script_path = or_current_release(&args.core_script_path, |release| {
        release.core_script_path.clone()
    })?;
    let ctm_script_path = or_current_release(&args.ctm_script_path, |release| {
        release.ctm_script_path.clone()
    })?;
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
        upgrade_input_path,
        core_output_path: args.core_output_path.clone(),
        core_script_path,
        ctm_script_path,
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

/// Read the multi-CTM config TOML and return per-CTM inputs. This release
/// only upgrades ZKsyncOS CTMs; prepare fails on anything else.
pub(super) fn load_ctm_config(path: &Path) -> anyhow::Result<Vec<CtmInputs>> {
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
pub(super) fn zk_governance_redeploy_decision(
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
