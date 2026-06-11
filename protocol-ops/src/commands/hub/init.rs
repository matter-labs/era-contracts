use alloy::primitives::{Address, B256};
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::hub::accept_ownership::{accept_ownership, AcceptOwnershipInput};
use crate::commands::hub::deploy::{deploy, DeployInput};
use crate::common::output::write_output_if_requested;

use crate::common::forge::scripts::deploy_ecosystem::DeployL1CoreContractsOutput;
use crate::common::{forge::ForgeRunner, logger, wallets::Wallet, SharedRunArgs};

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct HubInitArgs {
    /// Owner address (default: deployer)
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
    /// Era chain ID
    #[clap(long, default_value_t = 270, help_heading = "Advanced input")]
    pub era_chain_id: u64,
    /// Enable legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<B256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: HubInitArgs) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(args.deployer_address).await?;
    let owner = Wallet::resolve(args.owner, None, &sender)?;

    let input = DeployInput {
        owner: owner.address,
        era_chain_id: args.era_chain_id,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_salt: args.create2_factory_salt,
    };
    let output = hub_init(&mut runner, &sender, &owner, &input).await?;
    let bridgehub_addr = output.deployed_addresses.bridgehub.bridgehub_proxy_addr;

    write_output_if_requested("hub.init", &args.shared, &runner, &input, &output).await?;

    logger::info("Bridgehub contracts initialized");
    logger::info(format!("Bridgehub Proxy: {:#x}", bridgehub_addr));
    Ok(())
}

/// Initialize hub: deploy contracts and accept ownership.
pub async fn hub_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    input: &DeployInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    logger::step("Deploying Bridgehub contracts...");
    let t = std::time::Instant::now();
    let output = deploy(runner, deployer, input)?;
    logger::info(format!("[timing] hub.deploy: {:.2?}", t.elapsed()));

    logger::step("Accepting ownership of Bridgehub contracts...");
    let deployed = &output.deployed_addresses;
    let accept_input = AcceptOwnershipInput {
        bridgehub: deployed.bridgehub.bridgehub_proxy_addr,
        governance: deployed.governance_addr,
        chain_admin: deployed.chain_admin,
    };
    accept_ownership(runner, owner, &accept_input).await?;

    Ok(output)
}
