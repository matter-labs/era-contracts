//! Full v31 prepare flow: canonical [`V31UpgradeInner::prepare`] plus the
//! governance-ownership precondition needed for governance-owned proxies and
//! the operational-admin ServerNotifier upgrade step.
//!
//! Only the prepare phase has orchestration that warrants its own struct.
//! The governance phase is pure replay (read TOMLs, dispatch
//! `governanceExecuteCalls`) and lives as a free helper in
//! [`super::upgrade`].

use std::{fs, path::Path};

use alloy::hex;
use alloy::primitives::{Address, Bytes};
use anyhow::Context;
use serde::Deserialize;

use crate::common::abi::AdminFunctionsAbi;
use crate::common::env_config::{NewGatewayConfig, OwnableProxyEntry};
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::wallets::Wallet;

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
        self.run_pre_steps(runner, deployer).await?;
        let mut prepared = self.inner.prepare(runner, deployer, inputs).await?;
        self.run_ctm_admin_steps(runner, deployer, &prepared.ctm_tomls)?;
        self.run_aux_ownership_steps(runner, deployer, &prepared.core_toml, &prepared.ctm_tomls)
            .await?;

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
    ) -> anyhow::Result<()> {
        let governance = crate::common::l1_contracts::resolve_governance(
            &runner.rpc_url,
            self.inner.bridgehub(),
        )
        .await?;
        let wraps = encode_owner_wraps(&self.ownable_proxies);
        runner.run(
            runner
                .script_call(
                    AdminFunctionsAbi::ensureCtmsAndProxyAdminsOwnedByGovernanceWithWrapsCall {
                        _bridgehub: self.inner.bridgehub(),
                        _governance: governance,
                        _wraps: wraps,
                    },
                )
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
            let encoded_calls = hex::decode(encoded_calls_hex.trim_start_matches("0x"))
                .with_context(|| {
                    format!("invalid CTM admin calls hex in {}", entry.toml.display())
                })?;
            logger::step(format!(
                "Running v31 CTM admin calls for {:#x}",
                entry.proxy
            ));
            runner.run(
                runner
                    .script_call(AdminFunctionsAbi::executeOwnableCallsWithWrapsCall {
                        _callsToExecute: Bytes::from(encoded_calls),
                        _wraps: wraps.clone(),
                    })
                    .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
                    .with_wallet(deployer),
            )?;
        }
        Ok(())
    }

    /// After prepare, several Ownable2Step contracts still owned by the deployer
    /// (or whose transfer was only just initiated) are known only from the prepare
    /// output TOMLs: the core ecosystem AssetTracker + ChainRegistrationSender
    /// (from the Core TOML) and the CTM-adjacent GovernanceUpgradeTimer /
    /// RollupDAManager / ZKsync-OS verifier (from each CTM TOML). Transfer them to
    /// governance through the same owner-wrapper machinery and persist their
    /// deferred PUH accepts — these all land in the single stage-0 trailing block.
    async fn run_aux_ownership_steps(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        core_toml: &Path,
        ctm_entries: &[CtmPrepareEntry],
    ) -> anyhow::Result<()> {
        let targets = read_aux_ownership_targets(core_toml, ctm_entries)?;
        let governance = crate::common::l1_contracts::resolve_governance(
            &runner.rpc_url,
            self.inner.bridgehub(),
        )
        .await?;
        let wraps = encode_owner_wraps(&self.ownable_proxies);

        logger::step(format!(
            "Running v31 auxiliary ownership checks for {} target(s)",
            targets.len()
        ));
        runner.run(
            runner
                .script_call(
                    AdminFunctionsAbi::ensureOwnable2StepTargetsOwnedByGovernanceWithWrapsCall {
                        _targets: targets,
                        _governance: governance,
                        _wraps: wraps,
                    },
                )
                .with_wallet(deployer),
        )?;
        Ok(())
    }
}

fn read_aux_ownership_targets(
    core_toml: &Path,
    ctm_entries: &[CtmPrepareEntry],
) -> anyhow::Result<Vec<Address>> {
    #[derive(Deserialize)]
    struct CoreOutput {
        asset_tracker_proxy_addr: String,
        upgrade_addresses: CoreUpgradeAddresses,
    }

    #[derive(Deserialize)]
    struct CoreUpgradeAddresses {
        bridgehub: CoreBridgehub,
    }

    #[derive(Deserialize)]
    struct CoreBridgehub {
        chain_registration_sender_proxy_addr: String,
    }

    #[derive(Deserialize)]
    struct CtmOutput {
        deployed_addresses: DeployedAddresses,
        state_transition: StateTransition,
    }

    #[derive(Deserialize)]
    struct DeployedAddresses {
        l1_governance_upgrade_timer: String,
        l1_rollup_da_manager: String,
    }

    #[derive(Deserialize)]
    struct StateTransition {
        verifier_addr: String,
    }

    fn parse_addr(path: &Path, label: &str, value: &str) -> anyhow::Result<Address> {
        value.parse().with_context(|| {
            format!(
                "{label} in {} is not a valid address: {value}",
                path.display()
            )
        })
    }

    fn push_unique(targets: &mut Vec<Address>, target: Address) {
        if target != Address::ZERO && !targets.contains(&target) {
            targets.push(target);
        }
    }

    let mut targets = Vec::new();

    // Core ecosystem Ownable2Step contracts: AssetTracker + ChainRegistrationSender.
    // Their transfer to governance is initiated during the core deploy
    // (`updateContractConnections`); routing them through this aux flow folds the
    // deferred acceptOwnership() into stage 0 next to the CTM accepts.
    {
        let raw = fs::read_to_string(core_toml)
            .with_context(|| format!("read {}", core_toml.display()))?;
        let parsed: CoreOutput =
            toml::from_str(&raw).with_context(|| format!("parse {}", core_toml.display()))?;
        push_unique(
            &mut targets,
            parse_addr(
                core_toml,
                "asset_tracker_proxy_addr",
                &parsed.asset_tracker_proxy_addr,
            )?,
        );
        push_unique(
            &mut targets,
            parse_addr(
                core_toml,
                "upgrade_addresses.bridgehub.chain_registration_sender_proxy_addr",
                &parsed
                    .upgrade_addresses
                    .bridgehub
                    .chain_registration_sender_proxy_addr,
            )?,
        );
    }

    for entry in ctm_entries {
        let raw = fs::read_to_string(&entry.toml)
            .with_context(|| format!("read {}", entry.toml.display()))?;
        let parsed: CtmOutput =
            toml::from_str(&raw).with_context(|| format!("parse {}", entry.toml.display()))?;

        push_unique(
            &mut targets,
            parse_addr(
                &entry.toml,
                "deployed_addresses.l1_governance_upgrade_timer",
                &parsed.deployed_addresses.l1_governance_upgrade_timer,
            )?,
        );

        // RollupDAManagers with an explicit DA pair are accepted in stage 1
        // immediately before updateDAPair(). Others still need ownership
        // cleanup when their owner is legacy governance.
        if entry.rollup_da_pair.is_none() {
            push_unique(
                &mut targets,
                parse_addr(
                    &entry.toml,
                    "deployed_addresses.l1_rollup_da_manager",
                    &parsed.deployed_addresses.l1_rollup_da_manager,
                )?,
            );
        }

        // Era verifiers are not Ownable; ZKsync OS verifiers are Ownable2Step.
        if entry.is_zk_sync_os {
            push_unique(
                &mut targets,
                parse_addr(
                    &entry.toml,
                    "state_transition.verifier_addr",
                    &parsed.state_transition.verifier_addr,
                )?,
            );
        }
    }

    Ok(targets)
}

fn encode_owner_wraps(entries: &[OwnableProxyEntry]) -> Vec<AdminFunctionsAbi::OwnerWrap> {
    entries
        .iter()
        .map(|e| AdminFunctionsAbi::OwnerWrap {
            ownableContract: e.addr,
            kind: e.kind.to_solidity_u8(),
        })
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
