use alloy::primitives::{Address, B256};
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::commands::hub::deploy::{deploy, DeployInput};
use crate::common::abi::AdminFunctionsAbi;
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
    /// CREATE2 factory salt
    #[clap(long, help_heading = "Advanced input")]
    pub create2_factory_salt: Option<B256>,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: HubInitArgs) -> anyhow::Result<()> {
    let mut runner = ForgeRunner::new(&args.shared)?;
    let sender = runner.prepare_sender(args.deployer_address).await?;
    let owner = Wallet::resolve(args.owner, None, &sender)?;

    let input = HubInitInput {
        owner: owner.address,
        create2_factory_salt: args.create2_factory_salt,
    };
    let output = hub_init(&mut runner, &sender, &owner, &input).await?;
    let bridgehub_addr = output.deployed_addresses.bridgehub.bridgehub_proxy_addr;

    write_output_if_requested("hub.init", &args.shared, &runner, &input, &output).await?;

    logger::info("Bridgehub contracts initialized");
    logger::info(format!("Bridgehub Proxy: {:#x}", bridgehub_addr));
    Ok(())
}

/// Input parameters for hub init.
#[derive(Debug, Clone, Serialize)]
pub struct HubInitInput {
    pub owner: Address,
    pub create2_factory_salt: Option<B256>,
}

/// Initialize hub: deploy contracts and accept ownership.
pub async fn hub_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    input: &HubInitInput,
) -> anyhow::Result<DeployL1CoreContractsOutput> {
    logger::step("Deploying Bridgehub contracts...");
    let deploy_input = DeployInput {
        owner: input.owner,
        create2_factory_salt: input.create2_factory_salt,
    };
    let t = std::time::Instant::now();
    let output = deploy(runner, deployer, &deploy_input)?;
    logger::info(format!("[timing] hub.deploy: {:.2?}", t.elapsed()));

    logger::step("Accepting ownership of Bridgehub contracts...");
    let deployed = &output.deployed_addresses;
    let bridgehub = deployed.bridgehub.bridgehub_proxy_addr;
    let accept_scripts = [
        runner
            .script_call(AdminFunctionsAbi::chainAdminAcceptAdminCall {
                _chainAdmin: deployed.chain_admin,
                _target: bridgehub,
            })
            .with_wallet(owner)
            .with_timing_label("hub.accept_admin"),
        runner
            .script_call(AdminFunctionsAbi::governanceAcceptOwnerAggregatedCall {
                _governor: deployed.governance_addr,
                _bridgehub: bridgehub,
            })
            .with_wallet(owner)
            .with_timing_label("hub.accept_owner_aggregated"),
    ];
    runner.run_scripts(accept_scripts)?;

    Ok(output)
}
