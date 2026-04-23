use anyhow::Context;
use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::commands::ctm::accept_ownership::{accept_ownership, CtmAcceptOwnershipInput};
use crate::commands::ctm::deploy::{deploy, CtmDeployInput};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};

use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use crate::config::forge_interface::deploy_ctm::output::DeployCTMOutput;
use crate::types::VMOption;

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct CtmInitArgs {
    // Input
    /// Bridgehub proxy address
    #[clap(long, help_heading = "Input")]
    pub bridgehub: Address,
    /// VM type: zksyncos or eravm
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM, help_heading = "Input")]
    pub vm_type: VMOption,

    /// Owner address (default: sender)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    /// Deployer EOA address. Bootstrap is prepare-only: protocol-ops emits a
    /// directory of Safe bundles via `--out`; the deployer applies them with
    /// `dev execute-safe` (or any Safe-bundle-aware executor).
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
    /// Enable support for legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// ZK token asset ID
    #[clap(long, help_heading = "Advanced input")]
    pub zk_token_asset_id: Option<H256>,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: CtmInitArgs) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(args.deployer_address).await?;

    let owner = Wallet::resolve(args.owner, None, &deployer)?;

    // Bridgehub is the single source of truth — admin + owner come straight
    // from it. No override.
    let bridgehub_admin_addr =
        crate::common::l1_contracts::resolve_bridgehub_admin(&runner.rpc_url, args.bridgehub)
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
            crate::common::l1_contracts::resolve_governance(&runner.rpc_url, args.bridgehub)
                .await
                .context("resolving bridgehub.owner() from L1")?;
        runner.prepare_sender(owner_addr).await?
    };

    let ctm_input = CtmInitInput {
        bridgehub: args.bridgehub,
        owner: owner.address,
        vm_type: args.vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        zk_token_asset_id: args.zk_token_asset_id,
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
        vm_type: input.vm_type,
        reuse_gov_and_admin: input.reuse_gov_and_admin,
        with_testnet_verifier: input.with_testnet_verifier,
        with_legacy_bridge: input.with_legacy_bridge,
        zk_token_asset_id: input.zk_token_asset_id,
        create2_factory_salt: input.create2_factory_salt,
    };
    let t = std::time::Instant::now();
    let deploy_output = deploy(runner, deployer, &deploy_input)?;
    logger::info(format!("[timing] ctm.deploy: {:.2?}", t.elapsed()));
    let deployed = &deploy_output.deployed_addresses;
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;

    logger::step("Accepting ownership of CTM contracts...");
    let accept_input = CtmAcceptOwnershipInput {
        ctm_proxy,
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };
    accept_ownership(runner, owner, &accept_input).await?;

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

// ── Internal structs ────────────────────────────────────────────────────────

/// Input parameters for ctm init.
#[derive(Debug, Clone, Serialize)]
pub struct CtmInitInput {
    pub bridgehub: Address,
    pub owner: Address,
    pub vm_type: VMOption,
    pub reuse_gov_and_admin: bool,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub zk_token_asset_id: Option<H256>,
    pub create2_factory_salt: Option<H256>,
}
