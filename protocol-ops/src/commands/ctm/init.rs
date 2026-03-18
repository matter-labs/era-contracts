use std::path::PathBuf;

use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::commands::ctm::accept_ownership::{accept_ownership, CtmAcceptOwnershipInput};
use crate::commands::ctm::deploy::{deploy, CtmDeployInput, CtmDeployInputEcho, CtmDeployOutputData};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};
use crate::commands::output::CommandEnvelope;
use crate::common::{
    forge::{ForgeRunner, ForgeScriptArgs},
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

    // Signers
    /// Sender address
    #[clap(long, help_heading = "Signers")]
    pub sender: Option<Address>,
    /// Owner address (default: sender)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    // Auth
    /// Sender private key
    #[clap(long, visible_alias = "pk", help_heading = "Auth")]
    pub private_key: Option<H256>,
    /// Owner private key
    #[clap(long, visible_alias = "owner-pk", help_heading = "Auth")]
    pub owner_private_key: Option<H256>,
    /// Bridgehub governance owner private key
    #[clap(long, visible_alias = "bridgehub-owner-pk", help_heading = "Auth")]
    pub bridgehub_owner_private_key: Option<H256>,
    /// Bridgehub admin private key
    #[clap(long, visible_alias = "bridgehub-admin-pk", help_heading = "Auth")]
    pub bridgehub_admin_private_key: Option<H256>,

    // Execution
    /// L1 RPC URL
    #[clap(long, default_value = "http://localhost:8545", help_heading = "Execution")]
    pub l1_rpc_url: String,
    /// Simulate against anvil fork
    #[clap(long, help_heading = "Execution")]
    pub simulate: bool,

    // Output
    /// Write full JSON output to file
    #[clap(long, help_heading = "Output")]
    pub out: Option<PathBuf>,

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

    // Forge options
    #[clap(flatten)]
    #[serde(flatten)]
    pub forge_args: ForgeScriptArgs,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: CtmInitArgs) -> anyhow::Result<()> {
    let deployer = Wallet::parse(args.private_key, args.sender)?;
    let mut runner = ForgeRunner::new(args.simulate, &args.l1_rpc_url, args.forge_args.clone())?;

    let owner = Wallet::resolve(args.owner, args.owner_private_key, &deployer)?;

    let bridgehub_admin = Wallet::parse(args.bridgehub_admin_private_key, None)?;
    let bridgehub_owner = Wallet::resolve(
        None,
        args.bridgehub_owner_private_key,
        if args.reuse_gov_and_admin { &bridgehub_admin } else { &owner },
    )?;

    logger::info(format!("Bridgehub: {:#x}", args.bridgehub));

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

    if let Some(out_path) = &args.out {
        let deploy_input = CtmDeployInput {
            bridgehub: args.bridgehub,
            owner: owner.address,
            vm_type: args.vm_type,
            reuse_gov_and_admin: args.reuse_gov_and_admin,
            with_testnet_verifier: args.with_testnet_verifier,
            with_legacy_bridge: args.with_legacy_bridge,
            create2_factory_addr: args.create2_factory_addr,
            create2_factory_salt: args.create2_factory_salt,
        };
        let input_echo = CtmDeployInputEcho::from_input(&deploy_input);
        let output_data = CtmDeployOutputData::from_deploy_output(&ctm_output.deploy_output);
        let envelope = CommandEnvelope::new("ctm.init", input_echo, output_data, &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    logger::outro("CTM contracts initialized.");
    Ok(())
}

// ── Library function (for programmatic use) ─────────────────────────────────

/// Initialize CTM: deploy contracts, accept ownership, and register on bridgehub.
pub async fn ctm_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    admin: &Wallet,
    input: &CtmInitInput,
) -> anyhow::Result<CtmInitOutput> {
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
    let governance = deployed.governance_addr;
    let chain_admin = deployed.chain_admin;

    logger::step("Accepting ownership of CTM...");
    let accept_input = CtmAcceptOwnershipInput {
        ctm_proxy,
        governance,
        chain_admin,
    };
    accept_ownership(runner, owner, &accept_input).await?;

    logger::step("Registering CTM on Bridgehub...");
    let register_input = RegisterCtmInput {
        bridgehub: input.bridgehub,
        ctm_proxy,
    };
    register_ctm(runner, admin, &register_input)?;

    Ok(CtmInitOutput {
        deploy_output,
        ctm_proxy,
    })
}

// ── Internal structs ────────────────────────────────────────────────────────

/// Input parameters for ctm init.
#[derive(Debug, Clone)]
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

/// Output from ctm init.
#[derive(Debug, Clone)]
pub struct CtmInitOutput {
    pub deploy_output: DeployCTMOutput,
    pub ctm_proxy: Address,
}
