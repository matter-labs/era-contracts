use clap::Parser;
use ethers::types::{Address, H256};
use serde::{Deserialize, Serialize};

use crate::commands::ctm::init::{ctm_init, CtmInitInput};
use crate::commands::hub::init::{hub_init, HubInitInput};

use crate::commands::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet};
use crate::config::forge_interface::deploy_ctm::output::DeployCTMOutput;
use crate::config::forge_interface::deploy_ecosystem::output::DeployL1CoreContractsOutput;
use crate::types::VMOption;

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct EcosystemInitArgs {
    /// Owner address for the deployed contracts (default: deployer)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    /// Deployer EOA address. Bootstrap emits a directory of Safe bundles via
    /// `--out`; the deployer applies them with `--execute`, `dev execute-safe`,
    /// or any Safe-bundle-aware executor. No key is handed to the Forge
    /// simulation step.
    #[clap(long, help_heading = "Signers")]
    pub deployer_address: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    // Advanced input
    /// Era chain ID
    #[clap(long, default_value_t = 270, help_heading = "Advanced input")]
    pub era_chain_id: u64,
    /// VM type: zksyncos (default) or eravm
    #[clap(long, value_enum, default_value_t = VMOption::ZKSyncOsVM, help_heading = "Advanced input")]
    pub vm_type: VMOption,
    /// Use testnet verifier (default: true)
    #[clap(long, default_value_t = true, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_testnet_verifier: bool,
    /// Enable support for legacy bridge testing (default: false)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// ZK token asset ID
    #[clap(long, help_heading = "Advanced input")]
    pub zk_token_asset_id: Option<H256>,
    /// CREATE2 factory salt (random by default)
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<H256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: EcosystemInitArgs) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(args.deployer_address).await?;
    let owner = Wallet::resolve(args.owner, None, &sender)?;

    let input = EcosystemInitInput {
        sender: sender.address,
        owner: owner.address,
        era_chain_id: args.era_chain_id,
        vm_type: args.vm_type,
        with_testnet_verifier: args.with_testnet_verifier,
        with_legacy_bridge: args.with_legacy_bridge,
        zk_token_asset_id: args.zk_token_asset_id,
        create2_factory_salt: args.create2_factory_salt,
    };
    let output = ecosystem_init(&mut runner, &sender, &owner, &input).await?;

    write_output_if_requested("ecosystem.init", &args.shared, &runner, &input, &output).await?;

    logger::info("Ecosystem initialized");
    logger::info(format!(
        "Bridgehub Proxy: {:#x}",
        output.hub.deployed_addresses.bridgehub.bridgehub_proxy_addr
    ));
    logger::info(format!(
        "CTM Proxy: {:#x}",
        output
            .ctm
            .deployed_addresses
            .state_transition
            .state_transition_proxy_addr
    ));
    Ok(())
}

pub async fn ecosystem_init(
    runner: &mut ForgeRunner,
    sender: &Wallet,
    owner: &Wallet,
    input: &EcosystemInitInput,
) -> anyhow::Result<EcosystemInitOutputData> {
    // The deterministic CREATE2 factory is an EVM-wide constant
    // (0x4e59b4…c). The Solidity script uses it unconditionally via
    // `Utils.DETERMINISTIC_CREATE2_ADDRESS` — no override needed.

    // Initialize Bridgehub contracts
    let hub_input = HubInitInput {
        owner: owner.address,
        era_chain_id: input.era_chain_id,
        with_legacy_bridge: input.with_legacy_bridge,
        create2_factory_salt: input.create2_factory_salt,
    };
    let hub_output = hub_init(runner, sender, owner, &hub_input).await?;
    let bridgehub_addr = hub_output.deployed_addresses.bridgehub.bridgehub_proxy_addr;

    // Initialize CTM contracts
    let ctm_input = CtmInitInput {
        bridgehub: bridgehub_addr,
        owner: owner.address,
        vm_type: input.vm_type,
        reuse_gov_and_admin: true,
        with_testnet_verifier: input.with_testnet_verifier,
        with_legacy_bridge: input.with_legacy_bridge,
        zk_token_asset_id: input.zk_token_asset_id,
        create2_factory_salt: input.create2_factory_salt,
    };
    let ctm_output = ctm_init(runner, sender, owner, owner, &ctm_input).await?;

    Ok(EcosystemInitOutputData {
        hub: hub_output,
        ctm: ctm_output,
    })
}

// ── Input / Output structs ───────────────────────────────────────────────────

#[derive(Serialize)]
pub struct EcosystemInitInput {
    pub sender: Address,
    pub owner: Address,
    pub era_chain_id: u64,
    pub vm_type: VMOption,
    pub with_testnet_verifier: bool,
    pub with_legacy_bridge: bool,
    pub zk_token_asset_id: Option<H256>,
    pub create2_factory_salt: Option<H256>,
}

#[derive(Serialize)]
pub struct EcosystemInitOutputData {
    pub hub: DeployL1CoreContractsOutput,
    pub ctm: DeployCTMOutput,
}
