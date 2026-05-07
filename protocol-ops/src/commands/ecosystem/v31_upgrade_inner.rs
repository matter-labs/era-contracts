//! Canonical v31 prepare-phase orchestration.
//!
//! `V31UpgradeInner::prepare` fires `CoreUpgrade_v31.noGovernancePrepare`
//! once and `CTMUpgrade_v31.noGovernancePrepare` once per target CTM, all on
//! the supplied `ForgeRunner` so deployer broadcasts merge into one Safe
//! bundle.
//!
//! Real-world ecosystems also need a precondition (`ensureCtmsAndProxyAdmins
//! OwnedByGovernance`) before prepare; that lives in
//! [`super::v31_upgrade_full::V31UpgradeFull`], which composes this.
//!
//! The governance phase is not on this struct — it's a free helper in
//! [`super::upgrade`] because it has no state of its own (just file IO + ABI
//! passthrough).

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use ethers::types::{Address, H256};

use crate::abi_contracts::{CORE_UPGRADE_V31_CONTRACT, CTM_UPGRADE_V31_CONTRACT};
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
    /// Optional CREATE2 salt; random if `None`.
    pub create2_factory_salt: Option<H256>,
    /// Upgrade config TOML path relative to `l1-contracts/`.
    pub upgrade_input_path: String,
    /// Output TOML path for the core forge call (relative to l1-contracts/).
    pub core_output_path: String,
    /// `CoreUpgrade_v31` script path (relative to `l1-contracts/`).
    pub core_script_path: String,
    /// `CTMUpgrade_v31` script path (relative to `l1-contracts/`).
    pub ctm_script_path: String,
    /// Override for `isZKsyncOS` used by the CORE prepare (separate from
    /// per-CTM overrides because Core itself is CTM-agnostic but the script
    /// signature still needs the flag). When `None`, auto-resolved from any
    /// registered CTM via `ctm.isZKsyncOS()` (v31+ getter).
    pub core_is_zk_sync_os_override: Option<bool>,
}

/// Output of the prepare phase: the TOMLs each forge invocation wrote, in
/// the order the governance phase should replay them (core first, then per
/// CTM in input order).
pub struct V31PrepareOutput {
    pub core_toml: PathBuf,
    pub ctm_tomls: Vec<(Address, PathBuf)>,
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
    pub async fn prepare(
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
            let path = self
                .prepare_ctm(runner, deployer, inputs, ctm)
                .await
                .with_context(|| format!("ctm prepare ({:#x})", ctm.proxy))?;
            ctm_tomls.push((ctm.proxy, path));
        }

        Ok(V31PrepareOutput {
            core_toml,
            ctm_tomls,
        })
    }

    async fn prepare_core(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<PathBuf> {
        ensure_script_exists(self.contracts_path, &inputs.core_script_path)?;

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

        let create2_salt = inputs.create2_factory_salt.unwrap_or_else(H256::random);

        let script = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new(inputs.core_script_path.trim_start_matches('/')),
            )
            .with_contract_call(
                &CORE_UPGRADE_V31_CONTRACT,
                "noGovernancePrepare",
                ((
                    self.bridgehub,
                    is_zk_sync_os,
                    create2_salt,
                    inputs.upgrade_input_path.clone(),
                    inputs.core_output_path.clone(),
                ),),
            )?
            .with_broadcast()
            .with_ffi()
            .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
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
    ) -> anyhow::Result<PathBuf> {
        ensure_script_exists(self.contracts_path, &inputs.ctm_script_path)?;

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

        let create2_salt = inputs.create2_factory_salt.unwrap_or_else(H256::random);

        // Per-CTM output path so back-to-back prepares don't clobber each other.
        let output_path_str = format!("/script-out/v31-upgrade-ctm-{ctm_proxy:#x}.toml");
        let ctm_output_path = self
            .contracts_path
            .join(output_path_str.trim_start_matches('/'));
        let _ = fs::remove_file(&ctm_output_path);

        let l1_network = crate::types::L1Network::from_l1_rpc(&runner.rpc_url)?;
        let zk_token_asset_id = l1_network.zk_token_asset_id();

        let script = runner
            .script_path_from_root(
                self.contracts_path,
                Path::new(inputs.ctm_script_path.trim_start_matches('/')),
            )
            .with_contract_call(
                &CTM_UPGRADE_V31_CONTRACT,
                "noGovernancePrepare",
                ((
                    ctm_proxy,
                    bytecodes_supplier,
                    is_zk_sync_os,
                    rollup_da_manager,
                    create2_salt,
                    inputs.upgrade_input_path.clone(),
                    output_path_str.clone(),
                    governance,
                    zk_token_asset_id,
                ),),
            )?
            .with_broadcast()
            .with_ffi()
            .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
            .with_wallet(deployer);

        logger::step(format!("Running v31 ctm prepare for {ctm_proxy:#x}"));
        runner
            .run(script)
            .context("Failed to execute CTMUpgrade_v31.noGovernancePrepare")?;

        Ok(ctm_output_path)
    }
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
