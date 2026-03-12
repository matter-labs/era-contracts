use std::path::PathBuf;

use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};
use xshell::Shell;

use crate::commands::ctm::accept_ownership::{accept_ownership, CtmAcceptOwnershipInput};
use crate::commands::ctm::deploy::{deploy, CtmDeployInput, CtmDeployInputEcho, CtmDeployOutputData};
use crate::commands::hub::register_ctm::{register_ctm, RegisterCtmInput};
use crate::commands::output::CommandEnvelope;
use crate::common::{
    forge::{
        resolve_execution, resolve_owner_auth, resolve_secondary_auth, ExecutionMode, ForgeArgs,
        ForgeContext, ForgeRunner, SenderAuth,
    },
    logger,
};
use crate::config::forge_interface::deploy_ctm::output::DeployCTMOutput;
use crate::types::VMOption;
use crate::common::paths;

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
    pub forge_args: ForgeArgs,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: CtmInitArgs, shell: &Shell) -> anyhow::Result<()> {
    let foundry_scripts_path = paths::path_from_root("l1-contracts");

    let (sender_auth, sender, execution_mode) =
        resolve_execution(args.private_key, args.sender, args.simulate, &args.l1_rpc_url)?;
    let owner = args.owner.unwrap_or(sender);
    let is_simulation = matches!(execution_mode, ExecutionMode::Simulate(_));

    let owner_auth = resolve_owner_auth(
        owner, args.owner_private_key, sender, &sender_auth, is_simulation,
    )?;

    let bridgehub_owner_auth = resolve_secondary_auth(
        args.bridgehub_owner_private_key,
        "Governance owner (for accepting ownership)",
        &owner_auth,
    )?;
    if args.reuse_gov_and_admin && args.bridgehub_owner_private_key.is_none() {
        anyhow::bail!(
            "--bridgehub-owner-pk is required when --reuse-gov-and-admin=true \
            (the hub's governance owner must accept ownership)"
        );
    }

    let bridgehub_admin_auth = resolve_secondary_auth(
        args.bridgehub_admin_private_key,
        "Bridgehub admin (for CTM registration)",
        &bridgehub_owner_auth,
    )?;

    if is_simulation {
        logger::info(format!("Simulation mode: forking {} via anvil", args.l1_rpc_url));
    }

    let effective_rpc = execution_mode.rpc_url(&args.l1_rpc_url);
    let mut runner = ForgeRunner::new();

    // Step 1: Deploy CTM contracts (as sender)
    logger::info(format!("Deploying CTM contracts as sender: {:#x}", sender));
    logger::info(format!("Owner will be: {:#x}", owner));
    logger::info(format!("Bridgehub: {:#x}", args.bridgehub));

    let deploy_input = CtmDeployInput {
        bridgehub: args.bridgehub,
        owner,
        vm_type: args.vm_type,
        reuse_gov_and_admin: args.reuse_gov_and_admin,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_addr: args.create2_factory_addr,
        create2_factory_salt: args.create2_factory_salt,
    };

    let mut ctx = ForgeContext {
        shell,
        foundry_scripts_path: foundry_scripts_path.as_path(),
        runner: &mut runner,
        forge_args: &args.forge_args.script,
        l1_rpc_url: effective_rpc,
        auth: &sender_auth,
    };

    let deploy_output = deploy(&mut ctx, &deploy_input)?;

    let deployed = &deploy_output.deployed_addresses;
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;
    let governance = deployed.governance_addr;
    let chain_admin = deployed.chain_admin;

    // Step 2: Accept ownership (as governance owner)
    logger::info("Accepting ownership of CTM...");
    ctx.auth = &bridgehub_owner_auth;
    let accept_input = CtmAcceptOwnershipInput {
        ctm_proxy,
        governance,
        chain_admin,
    };
    accept_ownership(&mut ctx, &accept_input).await?;

    // Step 3: Register CTM on Bridgehub (as bridgehub admin)
    logger::info("Registering CTM on Bridgehub...");
    ctx.auth = &bridgehub_admin_auth;
    let register_input = RegisterCtmInput {
        bridgehub: args.bridgehub,
        ctm_proxy,
    };
    register_ctm(&mut ctx, &register_input)?;

    if let Some(out_path) = &args.out {
        let input_echo = CtmDeployInputEcho::from_input(&deploy_input);
        let output_data = CtmDeployOutputData::from_deploy_output(&deploy_output);
        let envelope = CommandEnvelope::new("ctm.init", input_echo, output_data, &runner);
        envelope.write_to_file(out_path)?;
        logger::info(format!("Full output written to: {}", out_path.display()));
    }

    if is_simulation {
        logger::outro(format!("CTM init simulation complete — CTM Proxy: {:#x}", ctm_proxy));
    } else {
        logger::outro(format!("CTM Proxy deployed at: {:#x}", ctm_proxy));
    }

    drop(execution_mode);
    Ok(())
}

// ── Library function (for programmatic use) ─────────────────────────────────

/// Initialize CTM: deploy contracts, accept ownership, and register on bridgehub.
///
/// `ctx.auth` is used for deployment. `owner_auth` for accepting ownership,
/// `admin_auth` for registering on bridgehub.
pub async fn ctm_init<'a>(
    ctx: &mut ForgeContext<'a>,
    input: &CtmInitInput,
    owner_auth: &'a SenderAuth,
    admin_auth: &'a SenderAuth,
) -> anyhow::Result<CtmInitOutput> {
    // Step 1: Deploy CTM contracts
    logger::info("Deploying CTM contracts...");
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
    let deploy_output = deploy(ctx, &deploy_input)?;

    let deployed = &deploy_output.deployed_addresses;
    let ctm_proxy = deployed.state_transition.state_transition_proxy_addr;
    let governance = deployed.governance_addr;
    let chain_admin = deployed.chain_admin;

    // Step 2: Accept ownership
    logger::info("Accepting ownership of CTM...");
    ctx.auth = owner_auth;
    let accept_input = CtmAcceptOwnershipInput {
        ctm_proxy,
        governance,
        chain_admin,
    };
    accept_ownership(ctx, &accept_input).await?;

    // Step 3: Register CTM on Bridgehub
    logger::info("Registering CTM on Bridgehub...");
    ctx.auth = admin_auth;
    let register_input = RegisterCtmInput {
        bridgehub: input.bridgehub,
        ctm_proxy,
    };
    register_ctm(ctx, &register_input)?;

    Ok(CtmInitOutput {
        deploy_output,
        ctm_proxy,
        governance,
        chain_admin,
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
    pub governance: Address,
    pub chain_admin: Address,
}
