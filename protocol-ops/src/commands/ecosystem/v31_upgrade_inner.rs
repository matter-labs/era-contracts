//! Canonical v31 prepare-phase orchestration.
//!
//! `V31UpgradeInner::prepare` fires `CoreUpgrade_v31.noGovernancePrepare`
//! once and `CTMUpgrade_v31.noGovernancePrepare` once per target CTM, all on
//! the supplied `ForgeRunner` so deployer broadcasts merge into one Safe
//! bundle.
//!
//! Real-world ecosystems also need governance-owned proxy preconditions and
//! operational admin call execution around prepare; those live in
//! [`super::v31_upgrade_full::V31UpgradeFull`], which composes this.
//!
//! The governance phase is not on this struct — it's a free helper in
//! [`super::upgrade`] because it has no state of its own (just file IO + ABI
//! passthrough).

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use alloy::primitives::{Address, B256};
use anyhow::Context;

use crate::common::abi::{ICTMUpgradeV31Abi, ICoreUpgradeV31Abi};
use crate::common::forge::scripts::{CORE_UPGRADE_V31_SCRIPT_PATH, CTM_UPGRADE_V31_SCRIPT_PATH};
use crate::common::wallets::Wallet;
use crate::common::{forge::ForgeRunner, logger};

// ── inputs / outputs ───────────────────────────────────────────────────────

/// Per-CTM inputs. One entry per `--ctm-proxy` (or per `[[ctm]]` row in a
/// `--ctm-config` TOML). All overrides are optional: when `None`, prepare_ctm
/// auto-resolves via on-chain getters (works on v31+ ecosystems; pre-v31
/// ecosystems must pass them explicitly because the getters don't exist).
pub struct CtmInputs {
    /// CTM proxy address.
    pub proxy: Address,
    /// Override for `isZKsyncOS`. Required on pre-v31 ecosystems.
    pub is_zk_sync_os: Option<bool>,
    /// Override for the bytecodes supplier address. Required on pre-v31.
    pub bytecodes_supplier: Option<Address>,
    /// Override for the rollup DA manager address. Required on pre-v31.
    pub rollup_da_manager: Option<Address>,
}

/// Inputs to the prepare phase. The CLI handler builds this from clap args.
pub struct V31PrepareInputs {
    /// Target CTMs. One forge invocation per entry.
    pub ctms: Vec<CtmInputs>,
    /// Optional CREATE2 salt for the Core prepare; random if `None`.
    pub create2_factory_salt: Option<B256>,
    /// Optional per-CTM CREATE2 salts. Keyed by CTM proxy address. Each CTM
    /// prepare must use a distinct salt because the contracts it deploys
    /// (notably `GovernanceUpgradeTimer`) have env-wide identical constructor
    /// args — same salt + same factory + same init code → same address →
    /// gov-replay's second `startTimer()` would revert. Supplied via the
    /// `[create2_factory_salts]` table in `upgrade-envs/v0.31.0-interopB/
    /// <env>.toml`; missing entries fall back to a random salt (legacy
    /// local-fixture path).
    pub create2_factory_salt_per_ctm: Option<HashMap<Address, B256>>,
    /// Upgrade config TOML path relative to `l1-contracts/`.
    pub upgrade_input_path: String,
    /// Output TOML path for the core forge call (relative to l1-contracts/).
    pub core_output_path: String,
    /// Override for `isZKsyncOS` used by the CORE prepare (separate from
    /// per-CTM overrides because Core itself is CTM-agnostic but the script
    /// signature still needs the flag). When `None`, auto-resolved from any
    /// registered CTM via `ctm.isZKsyncOS()` (v31+ getter).
    pub core_is_zk_sync_os_override: Option<bool>,
    /// ZK token asset ID used by CTM prepare. For named envs this comes from
    /// `upgrade-envs/permanent-values/<env>.toml`; otherwise it is explicitly
    /// supplied or falls back only for networks with a canonical value.
    pub zk_token_asset_id: B256,
}

/// Output of the prepare phase: the TOMLs each forge invocation wrote, in
/// the order the governance phase should replay them (core first, then per
/// CTM in input order, then the optional new-Gateway bring-up bundle).
pub struct V31PrepareOutput {
    pub core_toml: PathBuf,
    pub ctm_tomls: Vec<CtmPrepareEntry>,
    /// Empty when the env's `[new_gateway]` block isn't set. When present,
    /// each entry points at one `GatewayVotePreparation` output TOML (one
    /// per CTM deployed on the gateway); the merge logic in
    /// `upgrade::write_merged_ecosystem_toml` decodes
    /// `governance_calls_to_execute` from each and appends to stage 2.
    pub new_gateway_tomls: Vec<PathBuf>,
}

/// Per-CTM prepare result: where the script wrote its TOML, and the resolved
/// `is_zk_sync_os` flag (used downstream to label per-CTM sections in the
/// merged ecosystem TOML as `[ctms.era]` vs `[ctms.zksync_os]`).
pub struct CtmPrepareEntry {
    pub proxy: Address,
    pub toml: PathBuf,
    pub is_zk_sync_os: bool,
}

// ── struct ────────────────────────────────────────────────────────────────

pub struct V31UpgradeInner<'a> {
    contracts_path: &'a Path,
    bridgehub: Address,
}

impl<'a> V31UpgradeInner<'a> {
    pub fn new(contracts_path: &'a Path, bridgehub: Address) -> Self {
        Self {
            contracts_path,
            bridgehub,
        }
    }

    pub fn bridgehub(&self) -> Address {
        self.bridgehub
    }

    /// Run `CoreUpgrade_v31.noGovernancePrepare` then
    /// `CTMUpgrade_v31.noGovernancePrepare` once per CTM, all on the
    /// supplied runner. Returns the per-step output TOML paths.
    ///
    /// `pub(super)` so production callers must go through
    /// [`super::v31_upgrade_full::V31UpgradeFull::prepare`] — that wrapper
    /// runs the governance-owned proxy precondition first and executes
    /// operational admin calls afterwards.
    pub(super) async fn prepare(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<V31PrepareOutput> {
        if inputs.ctms.is_empty() {
            anyhow::bail!("V31UpgradeInner::prepare requires at least one CTM");
        }

        let core_toml = self
            .prepare_core(runner, deployer, inputs)
            .await
            .context("core prepare")?;

        let mut ctm_tomls = Vec::with_capacity(inputs.ctms.len());
        for ctm in &inputs.ctms {
            let (path, is_zk_sync_os) = self
                .prepare_ctm(runner, deployer, inputs, ctm)
                .await
                .with_context(|| format!("ctm prepare ({:#x})", ctm.proxy))?;
            ctm_tomls.push(CtmPrepareEntry {
                proxy: ctm.proxy,
                toml: path,
                is_zk_sync_os,
            });
        }

        Ok(V31PrepareOutput {
            core_toml,
            ctm_tomls,
            new_gateway_tomls: Vec::new(),
        })
    }

    async fn prepare_core(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<PathBuf> {
        ensure_script_exists(self.contracts_path, CORE_UPGRADE_V31_SCRIPT_PATH)?;

        // CTM is needed only to resolve `isZKsyncOS` — Core itself is
        // CTM-agnostic. Pick the first registered CTM as a witness, or skip
        // entirely if the caller supplied an explicit override (required on
        // pre-v31 ecosystems where the `ctm.isZKsyncOS()` getter does not exist).
        let is_zk_sync_os = match inputs.core_is_zk_sync_os_override {
            Some(v) => {
                logger::info(format!("ZKsync OS (override): {v}"));
                v
            }
            None => {
                let any_ctm = crate::common::l1_contracts::discover_ctm_proxy(
                    &runner.rpc_url,
                    self.bridgehub,
                )
                .await
                .context("Failed to discover any CTM on bridgehub")?;
                let resolved =
                    crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, any_ctm)
                        .await
                        .context("Failed to resolve isZKsyncOS from CTM")?;
                logger::info(format!(
                    "ZKsync OS (auto-resolved via CTM {any_ctm:#x}): {resolved}"
                ));
                resolved
            }
        };

        let upgrade_input = self
            .contracts_path
            .join(inputs.upgrade_input_path.trim_start_matches('/'));
        if !upgrade_input.exists() {
            anyhow::bail!("Upgrade input file not found: {}", upgrade_input.display());
        }

        let core_output_path = self
            .contracts_path
            .join(inputs.core_output_path.trim_start_matches('/'));
        let _ = fs::remove_file(&core_output_path);

        let create2_salt = inputs
            .create2_factory_salt
            .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>()));

        let script = runner
            .script_call(ICoreUpgradeV31Abi::noGovernancePrepareCall {
                _params: ICoreUpgradeV31Abi::CoreUpgradeParams {
                    bridgehubProxyAddress: self.bridgehub,
                    isZKsyncOS: is_zk_sync_os,
                    create2FactorySalt: create2_salt,
                    upgradeInputPath: inputs.upgrade_input_path.clone(),
                    outputPath: inputs.core_output_path.clone(),
                },
            })
            .with_disable_labels()
            .with_wallet(deployer);

        logger::step("Running v31 core prepare");
        runner
            .run(script)
            .context("Failed to execute CoreUpgrade_v31.noGovernancePrepare")?;

        Ok(core_output_path)
    }

    async fn prepare_ctm(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
        ctm: &CtmInputs,
    ) -> anyhow::Result<(PathBuf, bool)> {
        ensure_script_exists(self.contracts_path, CTM_UPGRADE_V31_SCRIPT_PATH)?;

        let ctm_proxy = ctm.proxy;

        // Find a chain on this CTM as a witness for rollup-DA-manager auto-
        // resolution.
        let chain_ids =
            crate::common::l1_contracts::resolve_all_chain_ids(&runner.rpc_url, self.bridgehub)
                .await
                .context("Failed to query registered chain IDs from bridgehub")?;
        let mut representative_chain: Option<u64> = None;
        for &cid in &chain_ids {
            let chain_ctm = crate::common::l1_contracts::resolve_ctm_proxy(
                &runner.rpc_url,
                self.bridgehub,
                cid,
            )
            .await
            .with_context(|| format!("resolving CTM for chain {cid}"))?;
            if chain_ctm == ctm_proxy {
                representative_chain = Some(cid);
                break;
            }
        }
        let representative_chain = representative_chain.with_context(|| {
            format!(
                "No registered chain uses CTM {ctm_proxy:#x}. Auto-resolution of \
                 rollup DA manager requires at least one registered chain on the \
                 target CTM."
            )
        })?;
        logger::info(format!(
            "CTM proxy: {ctm_proxy:#x} (representative chain {representative_chain})"
        ));

        let bytecodes_supplier = match ctm.bytecodes_supplier {
            Some(addr) => {
                logger::info(format!("Bytecodes supplier (override): {addr:#x}"));
                addr
            }
            None => {
                let resolved = crate::common::l1_contracts::resolve_bytecodes_supplier(
                    &runner.rpc_url,
                    ctm_proxy,
                )
                .await
                .context("Failed to auto-resolve bytecodes supplier from CTM")?;
                logger::info(format!("Bytecodes supplier (auto-resolved): {resolved:#x}"));
                resolved
            }
        };

        let is_zk_sync_os = match ctm.is_zk_sync_os {
            Some(v) => {
                logger::info(format!("ZKsync OS (override): {v}"));
                v
            }
            None => {
                let resolved =
                    crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm_proxy)
                        .await
                        .context("Failed to resolve isZKsyncOS from CTM")?;
                logger::info(format!("ZKsync OS (auto-resolved): {resolved}"));
                resolved
            }
        };

        let rollup_da_manager = match ctm.rollup_da_manager {
            Some(addr) => {
                logger::info(format!("RollupDAManager (override): {addr:#x}"));
                addr
            }
            None => {
                let zk_chain = crate::common::l1_contracts::resolve_zk_chain(
                    &runner.rpc_url,
                    self.bridgehub,
                    representative_chain,
                )
                .await
                .context("Failed to resolve ZK chain diamond proxy from bridgehub")?;
                let resolved = crate::common::l1_contracts::resolve_rollup_da_manager(
                    &runner.rpc_url,
                    zk_chain,
                )
                .await
                .context("Failed to auto-resolve RollupDAManager from ZK chain")?;
                logger::info(format!(
                    "RollupDAManager (auto-resolved via chain {representative_chain}): \
                     {resolved:#x}"
                ));
                resolved
            }
        };

        let governance =
            crate::common::l1_contracts::resolve_governance(&runner.rpc_url, self.bridgehub)
                .await
                .context("Failed to auto-resolve governance address from bridgehub")?;
        logger::info(format!("Governance (auto-resolved): {governance:#x}"));

        let chain_registration_sender = read_chain_registration_sender_proxy(
            &self
                .contracts_path
                .join(inputs.core_output_path.trim_start_matches('/')),
        )?;
        logger::info(format!(
            "ChainRegistrationSender (core prepare): {chain_registration_sender:#x}"
        ));

        // Per-CTM CREATE2 salt. Each CTM prepare deploys a few contracts
        // whose constructor args are env-wide constants — notably
        // `GovernanceUpgradeTimer(initialDelay, 2 weeks, ownerAddress,
        // ecosystemAdminAddress)` — so without per-CTM differentiation
        // Era's and Atlas's CTM-prepare CREATE2 calls would land at the
        // same address. The downstream gov-replay then calls
        // `startTimer()` twice on the same contract and the second one
        // reverts. The CLI / env config plumbs a distinct salt per CTM
        // proxy from `upgrade-envs/v0.31.0-interopB/<env>.toml
        // [create2_salts.per_ctm]`; if not provided we fall back to a
        // fresh random (legacy local-fixture path).
        let create2_salt = inputs
            .create2_factory_salt_per_ctm
            .as_ref()
            .and_then(|m| m.get(&ctm_proxy).copied())
            .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>()));
        logger::info(format!(
            "Per-CTM create2 salt: {create2_salt:#x} (ctm={ctm_proxy:#x})"
        ));

        // Per-CTM output path so back-to-back prepares don't clobber each other.
        let output_path_str = format!("/script-out/v31-upgrade-ctm-{ctm_proxy:#x}.toml");
        let ctm_output_path = self
            .contracts_path
            .join(output_path_str.trim_start_matches('/'));
        let _ = fs::remove_file(&ctm_output_path);

        let script = runner
            .script_call(ICTMUpgradeV31Abi::noGovernancePrepareCall {
                _params: ICTMUpgradeV31Abi::CTMUpgradeParams {
                    ctmProxy: ctm_proxy,
                    bytecodesSupplier: bytecodes_supplier,
                    isZKsyncOS: is_zk_sync_os,
                    rollupDAManager: rollup_da_manager,
                    create2FactorySalt: create2_salt,
                    upgradeInputPath: inputs.upgrade_input_path.clone(),
                    outputPath: output_path_str.clone(),
                    governance,
                    chainRegistrationSender: chain_registration_sender,
                    zkTokenAssetId: inputs.zk_token_asset_id,
                },
            })
            .with_disable_labels()
            .with_wallet(deployer);

        logger::step(format!("Running v31 ctm prepare for {ctm_proxy:#x}"));
        runner
            .run(script)
            .context("Failed to execute CTMUpgrade_v31.noGovernancePrepare")?;

        Ok((ctm_output_path, is_zk_sync_os))
    }
}

fn read_chain_registration_sender_proxy(core_toml: &Path) -> anyhow::Result<Address> {
    let raw =
        fs::read_to_string(core_toml).with_context(|| format!("read {}", core_toml.display()))?;
    let top: toml::Value =
        toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
    let value = top
        .get("upgrade_addresses")
        .and_then(|v| v.get("bridgehub"))
        .and_then(|v| v.get("chain_registration_sender_proxy_addr"))
        .and_then(|v| v.as_str())
        .with_context(|| {
            format!(
                "missing upgrade_addresses.bridgehub.chain_registration_sender_proxy_addr in {}",
                core_toml.display()
            )
        })?;

    value.parse().with_context(|| {
        format!(
            "chain_registration_sender_proxy_addr in {} is not a valid address: {}",
            core_toml.display(),
            value,
        )
    })
}

fn ensure_script_exists(contracts_path: &Path, script_path: &str) -> anyhow::Result<()> {
    let script_file_path = script_path
        .trim_start_matches('/')
        .split(':')
        .next()
        .unwrap_or(script_path);
    let script_full_path = contracts_path.join(script_file_path);
    if !script_full_path.exists() {
        anyhow::bail!("Script not found: {}", script_full_path.display());
    }
    Ok(())
}
