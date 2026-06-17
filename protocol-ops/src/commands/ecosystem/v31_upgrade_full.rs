//! Full v31 prepare flow: canonical [`V31UpgradeInner::prepare`] plus the
//! governance-ownership precondition needed for governance-owned proxies and
//! the operational-admin ServerNotifier upgrade step.
//!
//! Only the prepare phase has orchestration that warrants its own struct.
//! The governance phase is pure replay (read TOMLs, dispatch
//! `governanceExecuteCalls`) and lives as a free helper in
//! [`super::upgrade`].

use std::{fs, path::Path};

use anyhow::Context;
use ethers::types::{Address, Bytes};
use ethers::utils::hex;
use serde::Deserialize;

use crate::common::env_config::{NewGatewayConfig, OwnableProxyEntry};
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::wallets::Wallet;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

use super::new_gateway_prepare::prepare_new_gateway;
use super::v31_upgrade_inner::{
    CtmPrepareEntry, V31PrepareInputs, V31PrepareOutput, V31UpgradeInner,
};

pub struct V31UpgradeFull<'a> {
    inner: V31UpgradeInner<'a>,
    /// Registry of contract owners that need ownership-transfer calls wrapped
    /// (see `OwnerWrap` in `IAdminFunctions.sol`). Empty for envs where every
    /// current owner is already an EOA.
    ownable_proxies: Vec<OwnableProxyEntry>,
    /// Optional new-Gateway bring-up config from the env's `[new_gateway]`
    /// block. When present, the prepare phase runs
    /// `GatewayVotePreparation.s.sol` against this gateway on the same anvil
    /// fork and stashes the output TOML path in `V31PrepareOutput` for the
    /// stage-2 merge.
    new_gateway: Option<NewGatewayConfig>,
}

impl<'a> V31UpgradeFull<'a> {
    pub fn new(inner: V31UpgradeInner<'a>) -> Self {
        Self {
            inner,
            ownable_proxies: Vec::new(),
            new_gateway: None,
        }
    }

    pub fn with_ownable_proxies(mut self, proxies: Vec<OwnableProxyEntry>) -> Self {
        self.ownable_proxies = proxies;
        self
    }

    pub fn with_new_gateway(mut self, new_gateway: Option<NewGatewayConfig>) -> Self {
        self.new_gateway = new_gateway;
        self
    }

    /// Run the prepare phase: `ensureCtmsAndProxyAdminsOwnedByGovernance` as
    /// a precondition, then `inner.prepare`, then the CTM admin calls that are
    /// intentionally outside governance ownership (currently ServerNotifier).
    /// All steps broadcast against the supplied runner so every deployer/owner
    /// tx goes into the prepare Safe-bundle set.
    ///
    /// When `[new_gateway]` is configured, also runs `GatewayVotePreparation`
    /// after Core+CTM prepares — those broadcasts (CREATE2 deploys of the GW
    /// CTM contract set) merge into the same deployer Safe bundle.
    pub async fn prepare(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<V31PrepareOutput> {
        self.run_pre_steps(runner, deployer, inputs).await?;
        let mut prepared = self.inner.prepare(runner, deployer, inputs).await?;
        self.run_ctm_admin_steps(runner, deployer, &prepared.ctm_tomls)?;

        if let Some(ref new_gw) = self.new_gateway {
            // Look up the per-CTM salt: resolve the CTM proxy from the
            // representative chain, then find its salt in the prepare entries.
            let ctm_proxy = crate::common::l1_contracts::resolve_ctm_proxy(
                &runner.rpc_url,
                self.inner.bridgehub(),
                new_gw.ctm_representative_chain_id,
            )
            .await
            .ok();
            let gw_salt = ctm_proxy.and_then(|proxy| {
                prepared
                    .ctm_tomls
                    .iter()
                    .find(|e| e.proxy == proxy)
                    .and_then(|_| {
                        inputs
                            .create2_factory_salt_per_ctm
                            .as_ref()?
                            .get(&proxy)
                            .copied()
                    })
            });
            let path = prepare_new_gateway(
                runner,
                deployer,
                self.inner.bridgehub(),
                &prepared.core_toml,
                new_gw,
                new_gw.ctm_representative_chain_id,
                &prepared.ctm_tomls,
                inputs.zk_token_asset_id,
                gw_salt,
            )
            .await?;
            prepared.new_gateway_tomls.push(path);
        }

        Ok(prepared)
    }

    /// Pre-step hook: ensure governance owns each registered CTM + ProxyAdmin
    /// before the prepare deploys run. The downstream stage-1 governance
    /// calls (e.g. CTM ProxyAdmin upgradeAndCall) assume governance ownership;
    /// this is a no-op when ownership is already correct. Operational surfaces
    /// such as ServerNotifier are upgraded separately without transferring
    /// their ProxyAdmins to governance.
    ///
    /// The outer call has no permission gating — the deployer signs it. Inner
    /// `vm.startBroadcast(<owner>)` blocks emit the actual `transferOwnership`
    /// txs as the appropriate EOA owner; those land in that EOA's Safe bundle
    /// when the harness emits per-sender bundles. Contract owners listed in
    /// the env's `[[ownable_proxies]]` registry are routed through their
    /// wrapping shape (legacy Governance: `scheduleTransparent`+`executeInstant`,
    /// OZ ChainAdmin: `multicall`); contract owners *not* registered cause a
    /// hard revert.
    async fn run_pre_steps(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<()> {
        let governance = crate::common::l1_contracts::resolve_governance(
            &runner.rpc_url,
            self.inner.bridgehub(),
        )
        .await?;
        let wraps = encode_owner_wraps(&self.ownable_proxies);
        // Per-CTM RollupDAManagers to bring under governance (deduped). Sourced
        // from config (`CtmInputs.rollup_da_manager`) — the same value the Admin
        // facet embeds — rather than on-chain discovery, which a legacy chain on
        // the CTM could skew. CTMs that auto-resolve their manager (None) are
        // skipped; the Solidity side no-ops on already-governance-owned managers.
        let mut rollup_da_managers: Vec<Address> = Vec::new();
        for ctm in &inputs.ctms {
            if let Some(rdm) = ctm.rollup_da_manager {
                if !rollup_da_managers.contains(&rdm) {
                    rollup_da_managers.push(rdm);
                }
            }
        }
        runner.run(
            runner
                .with_script_call(
                    &ADMIN_FUNCTIONS_INVOCATION,
                    "ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps",
                    (
                        self.inner.bridgehub(),
                        governance,
                        wraps,
                        rollup_da_managers,
                    ),
                )?
                .with_wallet(deployer),
        )?;
        Ok(())
    }

    /// Execute the per-CTM admin calls generated by `CTMUpgrade_v31`. These
    /// calls target ownable operational admin surfaces whose ownership is
    /// intentionally preserved; `AdminFunctions` resolves each call target's
    /// current owner and routes through the configured owner wrapper when the
    /// owner is itself a contract.
    fn run_ctm_admin_steps(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        ctm_entries: &[CtmPrepareEntry],
    ) -> anyhow::Result<()> {
        let wraps = encode_owner_wraps(&self.ownable_proxies);
        for entry in ctm_entries {
            let encoded_calls_hex = read_server_notifier_upgrade_calls(&entry.toml)?;
            let encoded_calls = Bytes::from(
                hex::decode(encoded_calls_hex.trim_start_matches("0x")).with_context(|| {
                    format!("invalid CTM admin calls hex in {}", entry.toml.display())
                })?,
            );
            logger::step(format!(
                "Running v31 CTM admin calls for {:#x}",
                entry.proxy
            ));
            runner.run(
                runner
                    .with_script_call(
                        &ADMIN_FUNCTIONS_INVOCATION,
                        "executeOwnableCallsWithWraps",
                        (encoded_calls, wraps.clone()),
                    )?
                    .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
                    .with_wallet(deployer),
            )?;
        }
        Ok(())
    }
}

/// Marshal the registry into the `Vec<(Address, u8)>` shape that ethers
/// tokenizes as `tuple[]` matching Solidity's `OwnerWrap[]` argument.
fn encode_owner_wraps(entries: &[OwnableProxyEntry]) -> Vec<(Address, u8)> {
    entries
        .iter()
        .map(|e| (e.addr, e.kind.to_solidity_u8()))
        .collect()
}

#[derive(Debug, Deserialize)]
struct CtmAdminCallsToml {
    ctm_admin_calls: CtmAdminCalls,
}

#[derive(Debug, Deserialize)]
struct CtmAdminCalls {
    server_notifier_upgrade: String,
}

fn read_server_notifier_upgrade_calls(path: &Path) -> anyhow::Result<String> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let parsed: CtmAdminCallsToml =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    Ok(parsed.ctm_admin_calls.server_notifier_upgrade)
}
