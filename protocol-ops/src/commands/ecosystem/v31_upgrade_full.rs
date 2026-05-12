//! Full v31 prepare flow: canonical [`V31UpgradeInner::prepare`] plus the
//! `ensureCtmsAndProxyAdminsOwnedByGovernance` precondition needed on real
//! ecosystems (stage / mainnet).
//!
//! Only the prepare phase has orchestration that warrants its own struct.
//! The governance phase is pure replay (read TOMLs, dispatch
//! `governanceExecuteCalls`) and lives as a free helper in
//! [`super::upgrade`].

use ethers::types::Address;

use crate::common::env_config::{NewGatewayConfig, OwnableProxyEntry};
use crate::common::forge::ForgeRunner;
use crate::common::wallets::Wallet;
use crate::config::forge_interface::script_params::ADMIN_FUNCTIONS_INVOCATION;

use super::new_gateway_prepare::prepare_new_gateway;
use super::v31_upgrade_inner::{V31PrepareInputs, V31PrepareOutput, V31UpgradeInner};

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
    /// a precondition, then `inner.prepare`. Both broadcast against the
    /// supplied runner so all deployer/owner txs go into one Safe-bundle
    /// emission.
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

        if let Some(ref new_gw) = self.new_gateway {
            let path = prepare_new_gateway(
                runner,
                deployer,
                self.inner.bridgehub(),
                &prepared.core_toml,
                new_gw,
                &prepared.ctm_tomls,
                inputs.zk_token_asset_id,
            )
            .await?;
            prepared.new_gateway_toml = Some(path);
        }

        Ok(prepared)
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
