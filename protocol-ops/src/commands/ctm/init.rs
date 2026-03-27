use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::commands::ctm::accept_ownership::{accept_ownership, CtmAcceptOwnershipInput};
use crate::commands::ctm::deploy::{deploy, CtmDeployInput};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};
use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::ForgeRunner,
    logger,
    wallets::Wallet,
};
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

    /// Owner private key
    #[clap(long, visible_alias = "owner-pk", help_heading = "Auth")]
    pub owner_private_key: Option<H256>,
    /// Bridgehub governance owner private key
    #[clap(long, visible_alias = "bridgehub-owner-pk", help_heading = "Auth")]
    pub bridgehub_owner_private_key: Option<H256>,
    /// Bridgehub admin private key
    #[clap(long, visible_alias = "bridgehub-admin-pk", help_heading = "Auth")]
    pub bridgehub_admin_private_key: Option<H256>,

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
    /// CREATE2 factory address
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_addr: Option<Address>,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: CtmInitArgs) -> anyhow::Result<()> {
    let deployer = Wallet::parse(args.shared.private_key, args.shared.sender)?;
    let mut runner = ForgeRunner::new(
        args.shared.simulate,
        &args.shared.l1_rpc_url,
        args.shared.forge_args.clone(),
    )?;

    let owner = Wallet::resolve(args.owner, args.owner_private_key, &deployer)?;

    let bridgehub_admin = Wallet::parse(args.bridgehub_admin_private_key, None)?;
    let bridgehub_owner = Wallet::resolve(
        None,
        args.bridgehub_owner_private_key,
        if args.reuse_gov_and_admin { &bridgehub_admin } else { &owner },
    )?;

    let ctm_input = CtmInitInput {
        bridgehub: args.bridgehub,
        owner: owner.address,
        vm_type: args.vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };
    let ctm_output = ctm_init(&mut runner, &deployer, &bridgehub_owner, &bridgehub_admin, &ctm_input).await?;

    let ctm_proxy = ctm_output.deployed_addresses.state_transition.state_transition_proxy_addr;
    write_output_if_requested(
        "ctm.init",
        args.shared.out_path.as_deref(),
        &runner,
        &ctm_input,
        &ctm_output,
    )?;

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
        create2_factory_addr: input.create2_factory_addr,
        create2_factory_salt: input.create2_factory_salt,
    };
    let deploy_output = deploy(runner, deployer, &deploy_input)?;
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
    register_ctm(runner, admin, &register_input)?;

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
    pub create2_factory_addr: Option<Address>,
    pub create2_factory_salt: Option<H256>,
}
