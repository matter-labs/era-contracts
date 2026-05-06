//! Full v31 prepare flow: canonical [`V31UpgradeInner::prepare`] plus the
//! `ensureCtmsAndProxyAdminsOwnedByGovernance` precondition needed on real
//! ecosystems (stage / mainnet).
//!
//! Only the prepare phase has orchestration that warrants its own struct.
//! The governance phase is pure replay (read TOMLs, dispatch
//! `governanceExecuteCalls`) and lives as a free helper in
//! [`super::upgrade`].

use ethers::types::Address;

use crate::common::env_config::OwnableProxyEntry;
use crate::common::forge::ForgeRunner;
use crate::common::wallets::Wallet;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

use super::v31_upgrade_inner::{V31PrepareInputs, V31PrepareOutput, V31UpgradeInner};

pub struct V31UpgradeFull<'a> {
    inner: V31UpgradeInner<'a>,
    /// Registry of contract owners that need ownership-transfer calls wrapped
    /// (see `OwnerWrap` in `IAdminFunctions.sol`). Empty for envs where every
    /// current owner is already an EOA.
    ownable_proxies: Vec<OwnableProxyEntry>,
}

impl<'a> V31UpgradeFull<'a> {
    pub fn new(inner: V31UpgradeInner<'a>) -> Self {
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
    /// a precondition, then `inner.prepare`. Both broadcast against the
    /// supplied runner so all deployer/owner txs go into one Safe-bundle
    /// emission.
    pub async fn prepare(
        &self,
        runner: &mut ForgeRunner,
        deployer: &Wallet,
        inputs: &V31PrepareInputs,
    ) -> anyhow::Result<V31PrepareOutput> {
        self.run_pre_steps(runner, deployer).await?;
        self.inner.prepare(runner, deployer, inputs).await
    }

    /// Pre-step hook: ensure governance owns each registered CTM + ProxyAdmin
    /// before the prepare deploys run. The downstream stage-1 governance
    /// calls (e.g. ProxyAdmin upgradeAndCall) assume governance ownership;
    /// this is a no-op when ownership is already correct.
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
                .with_script_call(
                    &ADMIN_FUNCTIONS_INVOCATION,
                    "ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps",
                    (self.inner.bridgehub(), governance, wraps),
                )?
                .with_wallet(deployer),
        )?;
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
