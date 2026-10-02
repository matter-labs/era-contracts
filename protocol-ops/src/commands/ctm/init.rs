use alloy::primitives::{Address, B256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::ctm::deploy::{deploy, CtmDeployInput};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::env_config::EnvConfig;
use crate::common::forge::scripts::deploy_ctm::{
    DeployCTMDeployedAddressesOutput, DeployCTMOutput,
};
use crate::common::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmInitArgs {
    /// Per-env preset (`stage` / `testnet` / `mainnet` / `local`). Loads
    /// `upgrade-envs/permanent-values/<env>.toml` and supplies defaults for
    /// `--bridgehub`, `--zk-token-asset-id`, and `--owner` when those flags
    /// are omitted. Explicit flags still win.
    #[clap(long, help_heading = "Topology")]
    pub env: Option<String>,

    // Input
    /// Bridgehub proxy address. Required unless `--env` is set (then sourced
    /// from `permanent-values/<env>.toml`).
    #[clap(long, help_heading = "Input")]
    pub bridgehub: Option<Address>,

    /// Owner address (default: sender, or env's `owner_address` when `--env`
    /// is set).
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    /// Deployer EOA address. Bootstrap emits a directory of Safe bundles via
    /// `--out`; the deployer applies them with `dev execute-safe` or any
    /// Safe-bundle-aware executor.
    #[clap(long, help_heading = "Signers")]
    pub deployer_address: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    // Advanced input
    /// Reuse governance and admin contracts from hub
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub reuse_gov_and_admin: bool,
    /// Use testnet verifier
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_testnet_verifier: bool,
    /// Deploy the Airbender + ZiSK multi-proof verifier lane.
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub multi_proof_verifier: bool,
    /// Pre-deployed snarkJS Plonk verifier used by the ZiSK verifier.
    #[clap(long, help_heading = "Advanced input")]
    pub zisk_plonk_verifier_addr: Option<Address>,
    /// Optional pre-deployed ZiSK range verifier override.
    #[clap(long, help_heading = "Advanced input")]
    pub zisk_range_verifier_addr: Option<Address>,
    /// ZK token asset ID (defaults from env's `zk_token_asset_id` when
    /// `--env` is set).
    #[clap(long, help_heading = "Advanced input")]
    pub zk_token_asset_id: Option<B256>,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<B256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: CtmInitArgs) -> anyhow::Result<()> {
    let env_cfg = match args.env.as_deref() {
        Some(env) => Some(EnvConfig::load(env)?),
        None => None,
    };

    let bridgehub = args
        .bridgehub
        .or_else(|| env_cfg.as_ref().map(|c| c.bridgehub()))
        .ok_or_else(|| anyhow::anyhow!("--bridgehub or --env must be supplied"))?;
    let owner_override = args
        .owner
        .or_else(|| env_cfg.as_ref().and_then(|c| c.owner_address()));
    let zk_token_asset_id = args
        .zk_token_asset_id
        .or_else(|| env_cfg.as_ref().and_then(|c| c.zk_token_asset_id()));

    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(args.deployer_address).await?;

    let owner = Wallet::resolve(owner_override, None, &deployer)?;

    // Bridgehub is the single source of truth — admin + owner come straight
    // from it. No override.
    let bridgehub_admin_addr =
        crate::common::l1_contracts::resolve_bridgehub_admin(&runner.rpc_url, bridgehub)
            .await
            .context("resolving bridgehub.admin() from L1")?;
    let bridgehub_admin = runner.prepare_sender(bridgehub_admin_addr).await?;

    // When `--reuse-gov-and-admin` is set the governance owner collapses to
    // the bridgehub admin by construction; otherwise we query
    // `IOwnable(bridgehub).owner()`.
    let bridgehub_owner = if args.reuse_gov_and_admin {
        bridgehub_admin.clone()
    } else {
        let owner_addr =
            crate::common::l1_contracts::resolve_governance(&runner.rpc_url, bridgehub)
                .await
                .context("resolving bridgehub.owner() from L1")?;
        runner.prepare_sender(owner_addr).await?
    };

    let ctm_input = CtmInitInput {
        bridgehub,
        owner: owner.address,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        multi_proof_verifier: args.multi_proof_verifier,
        zisk_plonk_verifier_addr: args.zisk_plonk_verifier_addr,
        zisk_range_verifier_addr: args.zisk_range_verifier_addr,
        zk_token_asset_id,
        create2_factory_salt: args.create2_factory_salt,
    };
    let ctm_output = ctm_init(
        &mut runner,
        &deployer,
        &bridgehub_owner,
        &bridgehub_admin,
        &ctm_input,
    )
    .await?;

    let ctm_proxy = ctm_output
        .deployed_addresses
        .state_transition
        .state_transition_proxy_addr;
    write_output_if_requested("ctm.init", &args.shared, &runner, &ctm_input, &ctm_output).await?;

    logger::info("CTM contracts initialized");
    logger::info(format!("CTM Proxy: {:#x}", ctm_proxy));
    Ok(())
}

/// Initialize CTM contracts.
pub async fn ctm_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    admin: &Wallet,
    input: &CtmInitInput,
) -> anyhow::Result<DeployCTMOutput> {
    logger::step("Deploying CTM contracts...");
    let deploy_input = CtmDeployInput {
        bridgehub: input.bridgehub,
        owner: input.owner,
        reuse_gov_and_admin: input.reuse_gov_and_admin,
        with_testnet_verifier: input.with_testnet_verifier,
        multi_proof_verifier: input.multi_proof_verifier,
        zisk_plonk_verifier_addr: input.zisk_plonk_verifier_addr,
        zisk_range_verifier_addr: input.zisk_range_verifier_addr,
        zk_token_asset_id: input.zk_token_asset_id,
        create2_factory_salt: input.create2_factory_salt,
    };
    let t = std::time::Instant::now();
    let deploy_output = deploy(runner, deployer, &deploy_input)?;
    logger::info(format!("[timing] ctm.deploy: {:.2?}", t.elapsed()));
    let deployed = &deploy_output.deployed_addresses;
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;
    logger::step("Accepting ownership of CTM contracts...");
    // `chainAdminAccept*` broadcast as the forge `--sender`, which must be the
    // ChainAdmin's owner (ChainAdminOwnable.multicall is onlyOwner) — not the
    // ChainAdmin contract itself, which is what `admin` is for standalone
    // `ctm init`. Resolve it from the freshly deployed state instead.
    let chain_admin_owner_addr =
        crate::common::l1_contracts::resolve_ownable_owner(&runner.rpc_url, deployed.chain_admin)
            .await
            .context("resolving ChainAdmin.owner() for the CTM ownership hand-off")?;
    let chain_admin_owner = runner.prepare_sender(chain_admin_owner_addr).await?;
    // DeployCTM hands ValidatorTimelock to `config.ownerAddress` directly.
    let ctm_owner = runner.prepare_sender(input.owner).await?;

    let accept_scripts: Vec<_> = ctm_ownership_acceptances(deployed, input.owner)
        .into_iter()
        .map(|acceptance| match acceptance {
            CtmAcceptance::GovernanceAcceptOwner { target, label } => runner
                .script_call(AdminFunctionsAbi::governanceAcceptOwnerCall {
                    _governor: deployed.governance_addr,
                    _target: target,
                })
                .with_wallet(owner)
                .with_timing_label(label),
            CtmAcceptance::ChainAdminAcceptAdmin { target, label } => runner
                .script_call(AdminFunctionsAbi::chainAdminAcceptAdminCall {
                    _chainAdmin: deployed.chain_admin,
                    _target: target,
                })
                .with_wallet(&chain_admin_owner)
                .with_timing_label(label),
            CtmAcceptance::ChainAdminAcceptOwner { target, label } => runner
                .script_call(AdminFunctionsAbi::chainAdminAcceptOwnerCall {
                    _chainAdmin: deployed.chain_admin,
                    _target: target,
                })
                .with_wallet(&chain_admin_owner)
                .with_timing_label(label),
            CtmAcceptance::OwnerAcceptOwner {
                target,
                owner: pending_owner,
                label,
            } => runner
                .script_call(AdminFunctionsAbi::governanceAcceptOwnerConditionalCall {
                    _governor: pending_owner,
                    _target: target,
                })
                .with_wallet(&ctm_owner)
                .with_timing_label(label),
        })
        .collect();
    runner.run_scripts(accept_scripts)?;

    logger::step("Registering CTM on Bridgehub...");
    let register_input = RegisterCtmInput {
        bridgehub: input.bridgehub,
        ctm_proxy,
    };
    let t = std::time::Instant::now();
    register_ctm(runner, admin, &register_input)?;
    logger::info(format!("[timing] ctm.register: {:.2?}", t.elapsed()));

    Ok(deploy_output)
}

// ── Ownership hand-off ──────────────────────────────────────────────────────

/// One pending ownership/adminship transfer left by `DeployCTM.updateOwners()`
/// and the AdminFunctions call that accepts it on behalf of the right party.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtmAcceptance {
    /// `Ownable2Step` pending to the CTM's Governance contract; accepted via a
    /// Governance operation (the script broadcasts as `Governance.owner()`).
    GovernanceAcceptOwner {
        target: Address,
        label: &'static str,
    },
    /// Diamond-style `setPendingAdmin` to the ChainAdmin; accepted via the
    /// ChainAdmin multicall, sent by the ChainAdmin owner.
    ChainAdminAcceptAdmin {
        target: Address,
        label: &'static str,
    },
    /// `Ownable2Step` pending to the ChainAdmin; accepted via the ChainAdmin
    /// multicall, sent by the ChainAdmin owner.
    ChainAdminAcceptOwner {
        target: Address,
        label: &'static str,
    },
    /// `Ownable2Step` pending to the owner EOA, which accepts it directly.
    OwnerAcceptOwner {
        target: Address,
        owner: Address,
        label: &'static str,
    },
}

/// Every transfer `DeployCTM.updateOwners()` starts, paired with its acceptor:
/// CTM owner + RollupDAManager → governance, CTM admin + ServerNotifier →
/// ChainAdmin, ValidatorTimelock → `config.ownerAddress`. Accepting all of
/// them leaves the deployer owning nothing.
pub fn ctm_ownership_acceptances(
    deployed: &DeployCTMDeployedAddressesOutput,
    owner: Address,
) -> Vec<CtmAcceptance> {
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;
    vec![
        CtmAcceptance::GovernanceAcceptOwner {
            target: ctm_proxy,
            label: "ctm.accept_owner",
        },
        CtmAcceptance::ChainAdminAcceptAdmin {
            target: ctm_proxy,
            label: "ctm.accept_admin",
        },
        CtmAcceptance::GovernanceAcceptOwner {
            target: deployed.l1_rollup_da_manager,
            label: "ctm.accept_rollup_da_manager_owner",
        },
        CtmAcceptance::ChainAdminAcceptOwner {
            target: deployed.server_notifier_proxy_addr,
            label: "ctm.accept_server_notifier_owner",
        },
        CtmAcceptance::OwnerAcceptOwner {
            target: deployed.validator_timelock_addr,
            owner,
            label: "ctm.accept_validator_timelock_owner",
        },
    ]
}

// ── Internal structs ────────────────────────────────────────────────────────

/// Input parameters for ctm init.
#[derive(Debug, Clone, Serialize)]
pub struct CtmInitInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub multi_proof_verifier: bool,
    pub zisk_plonk_verifier_addr: Option<Address>,
    pub zisk_range_verifier_addr: Option<Address>,
    pub zk_token_asset_id: Option<B256>,
    pub create2_factory_salt: Option<B256>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::forge::scripts::deploy_ctm::L1StateTransitionOutput;

    fn addr(byte: u8) -> Address {
        Address::repeat_byte(byte)
    }

    fn deployed() -> DeployCTMDeployedAddressesOutput {
        DeployCTMDeployedAddressesOutput {
            governance_addr: addr(0x01),
            transparent_proxy_admin_addr: addr(0x02),
            validator_timelock_addr: addr(0x03),
            chain_admin: addr(0x04),
            state_transition: L1StateTransitionOutput {
                state_transition_proxy_addr: addr(0x05),
                verifier_addr: addr(0x06),
                airbender_verifier_addr: None,
                zisk_verifier_addr: None,
                zisk_testnet_verifier_addr: None,
                multi_proof_verifier_addr: None,
                genesis_upgrade_addr: addr(0x07),
                default_upgrade_addr: addr(0x08),
                bytecodes_supplier_addr: addr(0x09),
            },
            rollup_l1_da_validator_addr: addr(0x0a),
            no_da_validium_l1_validator_addr: addr(0x0b),
            avail_l1_da_validator_addr: addr(0x0c),
            l1_rollup_da_manager: addr(0x0d),
            blobs_zksync_os_l1_da_validator_addr: Some(addr(0x0e)),
            server_notifier_proxy_addr: addr(0x0f),
        }
    }

    /// Mirrors `DeployCTM.updateOwners()`: each transfer it starts is accepted
    /// exactly once, by the party it was handed to.
    #[test]
    fn every_ctm_hand_off_is_accepted_by_its_recipient() {
        let owner = addr(0x42);
        let d = deployed();
        let acceptances = ctm_ownership_acceptances(&d, owner);

        let strip = |a: &CtmAcceptance| match *a {
            CtmAcceptance::GovernanceAcceptOwner { target, .. } => {
                ("governance-owner", target, None)
            }
            CtmAcceptance::ChainAdminAcceptAdmin { target, .. } => {
                ("chain-admin-admin", target, None)
            }
            CtmAcceptance::ChainAdminAcceptOwner { target, .. } => {
                ("chain-admin-owner", target, None)
            }
            CtmAcceptance::OwnerAcceptOwner { target, owner, .. } => {
                ("eoa-owner", target, Some(owner))
            }
        };
        let got: Vec<_> = acceptances.iter().map(strip).collect();
        let ctm = d.state_transition.state_transition_proxy_addr;
        let expected = vec![
            ("governance-owner", ctm, None),
            ("chain-admin-admin", ctm, None),
            ("governance-owner", d.l1_rollup_da_manager, None),
            ("chain-admin-owner", d.server_notifier_proxy_addr, None),
            ("eoa-owner", d.validator_timelock_addr, Some(owner)),
        ];
        assert_eq!(got, expected);
    }

    /// Timing labels are how the per-step forge invocations show up in logs;
    /// keep them distinct so a failing step is identifiable.
    #[test]
    fn ctm_acceptance_labels_are_unique() {
        let acceptances = ctm_ownership_acceptances(&deployed(), addr(0x42));
        let mut labels: Vec<_> = acceptances
            .iter()
            .map(|a| match *a {
                CtmAcceptance::GovernanceAcceptOwner { label, .. }
                | CtmAcceptance::ChainAdminAcceptAdmin { label, .. }
                | CtmAcceptance::ChainAdminAcceptOwner { label, .. }
                | CtmAcceptance::OwnerAcceptOwner { label, .. } => label,
            })
            .collect();
        let total = labels.len();
        labels.sort();
        labels.dedup();
        assert_eq!(labels.len(), total);
    }
}
