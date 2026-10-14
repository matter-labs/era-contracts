//! Full prepare flow: canonical [`UpgradeInner::prepare`] plus the
//! governance-ownership precondition needed for governance-owned proxies and
//! the CTM-admin calls the CTM prepare emits (the registry bootstrap's
//! ServerNotifier handover; none on a recurring upgrade).
//!
//! Only the prepare phase has orchestration that warrants its own struct.
//! The governance phase is pure replay (read TOMLs, dispatch
//! `governanceExecuteCalls`) and lives as a free helper in
//! [`super::upgrade`].

use std::{fs, path::Path};

use alloy::primitives::Bytes;
use anyhow::Context;
use serde::Deserialize;

use crate::common::abi::AdminFunctionsAbi;
use crate::common::env_config::OwnableProxyEntry;
use crate::common::forge::ForgeRunner;
use crate::common::governance_calls::{decode_calls, encode_calls};
use crate::common::logger;
use crate::common::wallets::Wallet;

use super::upgrade_inner::{
    CtmInputs, CtmPrepareEntry, PrepareInputs, PrepareOutput, UpgradeInner,
};

pub struct UpgradeFull<'a> {
    inner: UpgradeInner<'a>,
    /// Registry of contract owners that need ownership-transfer calls wrapped
    /// (see `OwnerWrap` in `IAdminFunctions.sol`). Empty for envs where every
    /// current owner is already an EOA.
    ownable_proxies: Vec<OwnableProxyEntry>,
}

impl<'a> UpgradeFull<'a> {
    pub fn new(inner: UpgradeInner<'a>) -> Self {
        Self {
            inner,
            ownable_proxies: Vec::new(),
        }
    }

    pub fn with_ownable_proxies(mut self, proxies: Vec<OwnableProxyEntry>) -> Self {
        self.ownable_proxies = proxies;
        self
    }

    /// Run the prepare phase: `ensureCtmsAndProxyAdminsOwnedByGovernance` as
    /// a precondition, then `inner.prepare`, then the CTM-admin calls the CTM
    /// prepare emitted (`run_ctm_admin_steps`). All steps broadcast
    /// against the supplied runner so every deployer/owner tx goes into the
    /// prepare Safe-bundle set.
    pub async fn prepare(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &PrepareInputs,
    ) -> anyhow::Result<PrepareOutput> {
        let ctm = single_ctm(&inputs.ctms)?;
        self.run_pre_steps(runner, deployer).await?;
        let prepared = self.inner.prepare(runner, deployer, inputs, ctm).await?;
        self.run_ctm_admin_steps(runner, deployer, &prepared.ctm_tomls)?;
        Ok(prepared)
    }

    /// Pre-step hook: ensure governance owns each registered CTM + ProxyAdmin
    /// before the prepare deploys run. The downstream governance bundle
    /// (e.g. the bootstrap's CTM and ProxyAdmin handovers) assumes governance
    /// ownership; this is a no-op when ownership is already correct.
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

    /// Execute the per-CTM admin calls the CTM upgrade script emitted under
    /// `[ctm_admin_calls] server_notifier_handover`: the ChainAdmin's half of
    /// the bootstrap's one-time ServerNotifier handover (see "ServerNotifier: a
    /// one-time handover, then an ordinary CTM-domain proxy" in
    /// `docs/upgrade-operations.md`), empty on a recurring upgrade.
    /// `AdminFunctions` resolves each call target's current owner and routes
    /// through the configured owner wrapper when the owner is itself a
    /// contract.
    fn run_ctm_admin_steps(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        ctm_entries: &[CtmPrepareEntry],
    ) -> anyhow::Result<()> {
        let wraps = encode_owner_wraps(&self.ownable_proxies);
        for entry in ctm_entries {
            let calls = decode_calls(&read_server_notifier_handover_calls(&entry.toml)?)
                .with_context(|| {
                    format!("invalid CTM admin calls hex in {}", entry.toml.display())
                })?;
            if calls.is_empty() {
                continue;
            }
            logger::step(format!(
                "Running {} CTM admin call(s) for {:#x}",
                calls.len(),
                entry.proxy
            ));
            runner.run(
                runner
                    .script_call(AdminFunctionsAbi::executeOwnableCallsWithWrapsCall {
                        _callsToExecute: Bytes::from(encode_calls(&calls)),
                        _wraps: wraps.clone(),
                    })
                    .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
                    .with_wallet(deployer),
            )?;
        }
        Ok(())
    }
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
    server_notifier_handover: String,
}

/// The abi-encoded `Call[]` hex of `[ctm_admin_calls] server_notifier_handover`.
fn read_server_notifier_handover_calls(path: &Path) -> anyhow::Result<String> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let parsed: CtmAdminCallsToml =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    Ok(parsed.ctm_admin_calls.server_notifier_handover)
}

/// Validate before ownership/setup actions, then keep the internal prepare path scalar.
fn single_ctm(ctms: &[CtmInputs]) -> anyhow::Result<&CtmInputs> {
    let [ctm] = ctms else {
        anyhow::bail!(
            "this upgrade requires exactly one CTM; any number of chains may belong to that CTM"
        );
    };
    Ok(ctm)
}

#[cfg(test)]
mod single_ctm_tests {
    use super::*;
    use alloy::primitives::Address;

    #[test]
    fn selects_the_original_single_ctm_input() {
        let ctms = [CtmInputs {
            proxy: Address::repeat_byte(0x11),
            rollup_da_manager: Some(Address::repeat_byte(0x22)),
        }];
        let selected = single_ctm(&ctms).unwrap();
        assert!(std::ptr::eq(selected, &ctms[0]));
        assert_eq!(selected.rollup_da_manager, ctms[0].rollup_da_manager);
    }

    #[test]
    fn rejects_no_ctm_before_prepare() {
        assert!(single_ctm(&[]).is_err());
    }

    #[test]
    fn rejects_multiple_ctms_for_bootstrap_and_recurring_upgrades() {
        let ctms = [
            CtmInputs {
                proxy: Address::repeat_byte(0x11),
                rollup_da_manager: None,
            },
            CtmInputs {
                proxy: Address::repeat_byte(0x22),
                rollup_da_manager: None,
            },
        ];
        assert!(single_ctm(&ctms).is_err());
    }
}

#[cfg(test)]
mod ctm_admin_calls_tests {
    use super::*;
    use crate::common::governance_calls::{empty_calls_hex, GovernanceCall};
    use alloy::primitives::{Address, U256};

    fn read(section: &str) -> anyhow::Result<String> {
        let dir = std::env::temp_dir().join(format!(
            "protocol-ops-ctm-admin-calls-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ctm.toml");
        fs::write(&path, section).unwrap();
        read_server_notifier_handover_calls(&path)
    }

    /// The section a recurring prepare writes: the handover key with an EMPTY `Call[]` and zero
    /// administrators, which `run_ctm_admin_steps` skips.
    #[test]
    fn a_recurring_prepare_carries_an_empty_handover() {
        let hex = read(&format!(
            "[ctm_admin_calls]\n\
             chain_admin = \"0x0000000000000000000000000000000000000000\"\n\
             chain_admin_owner = \"0x0000000000000000000000000000000000000000\"\n\
             server_notifier_handover = \"{}\"\n",
            empty_calls_hex()
        ))
        .unwrap();
        assert!(decode_calls(&hex).unwrap().is_empty());
    }

    #[test]
    fn the_bootstrap_handover_calls_round_trip() {
        let call = GovernanceCall {
            target: Address::repeat_byte(0x11),
            value: U256::ZERO,
            data: vec![0xf2, 0xfd, 0xe3, 0x8b],
        };
        let hex = read(&format!(
            "[ctm_admin_calls]\nserver_notifier_handover = \"0x{}\"\n",
            alloy::hex::encode(encode_calls(std::slice::from_ref(&call)))
        ))
        .unwrap();
        let calls = decode_calls(&hex).unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].target, call.target);
        assert_eq!(calls[0].data, call.data);
    }

    /// An output from before the handover (`server_notifier_upgrade`, the recurring notifier
    /// swap) is refused rather than read as "no admin calls".
    #[test]
    fn the_retired_notifier_upgrade_key_is_refused() {
        let err = read(&format!(
            "[ctm_admin_calls]\nserver_notifier_upgrade = \"{}\"\n",
            empty_calls_hex()
        ))
        .unwrap_err();
        assert!(
            format!("{err:#}").contains("server_notifier_handover"),
            "{err:#}"
        );
    }
}
