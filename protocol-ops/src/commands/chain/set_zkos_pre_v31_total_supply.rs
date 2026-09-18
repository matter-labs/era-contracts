use alloy::primitives::{Address, U256};
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::AdminFunctionsAbi;
use crate::common::addresses::ZERO_ADDRESS;
use crate::common::forge::ForgeRunner;
use crate::common::logger;
use crate::common::SharedRunArgs;

#[derive(Serialize)]
struct SetZkosPreV31TotalSupplyOutput {
    chain_id: u64,
    admin_address: Address,
    access_control_restriction: Address,
    bridgehub: Address,
    pre_v31_total_supply: String,
}

/// Set the ZKsync OS pre-v31 base-token total supply.
///
/// Drives `AdminFunctions.s.sol::setZKsyncOSPreV31TotalSupply(...)` against a
/// forked anvil, emits a Gnosis Safe Transaction Builder JSON bundle via
/// `--out`, and never broadcasts to the real chain. Apply the bundle via
/// `protocol-ops dev execute-safe` or Safe UI.
#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainSetZkosPreV31TotalSupplyArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub topology: crate::common::EcosystemChainArgs,

    /// AccessControlRestriction contract address.
    /// Use `ZERO_ADDRESS` for Ownable ChainAdmin.
    #[clap(long, default_value = ZERO_ADDRESS)]
    pub access_control_restriction: Address,

    /// Pre-v31 base-token total supply. Decimal or 0x-prefixed uint256.
    #[clap(long)]
    pub pre_v31_total_supply: String,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,
}

pub async fn run(args: ChainSetZkosPreV31TotalSupplyArgs) -> anyhow::Result<()> {
    let (bridgehub, chain_id) = args.topology.resolve()?;
    let mut runner = ForgeRunner::new(&args.shared)?;
    let pre_v31_total_supply = args
        .pre_v31_total_supply
        .parse::<U256>()
        .context("invalid pre_v31_total_supply: expected decimal or hex uint256")?;

    let admin_address =
        crate::common::l1_contracts::resolve_chain_admin(&runner.rpc_url, bridgehub, chain_id)
            .await
            .context("resolving chain admin from L1")?;
    let sender = runner
        .prepare_chain_admin_broadcaster(bridgehub, chain_id, args.access_control_restriction)
        .await?;

    let forge = runner
        .script_call(AdminFunctionsAbi::setZKsyncOSPreV31TotalSupplyCall {
            _bridgehub: bridgehub,
            _accessControlRestriction: args.access_control_restriction,
            _chainId: U256::from(chain_id),
            _preV31TotalSupply: pre_v31_total_supply,
            _shouldSend: true,
        })
        .with_gas_limit(crate::common::forge::DEFAULT_SCRIPT_GAS_LIMIT)
        .with_wallet(&sender);

    logger::step(
        "Preparing set-zkos-pre-v31-total-supply Safe bundle via AdminFunctions.s.sol (simulation)",
    );
    logger::info(format!("Bridgehub: {:#x}", bridgehub));
    logger::info(format!("Chain ID: {chain_id}"));
    logger::info(format!("Admin address: {:#x}", admin_address));
    logger::info(format!(
        "Access control restriction: {:#x}",
        args.access_control_restriction
    ));
    logger::info(format!(
        "Pre-v31 total supply: {}",
        args.pre_v31_total_supply
    ));
    logger::info(format!("RPC URL: {}", args.shared.l1_rpc_url));

    runner
        .run(forge)
        .context("Failed to prepare set-zkos-pre-v31-total-supply")?;

    crate::common::output::write_output_if_requested(
        "chain.set-zkos-pre-v31-total-supply",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &SetZkosPreV31TotalSupplyOutput {
            chain_id,
            admin_address,
            access_control_restriction: args.access_control_restriction,
            bridgehub,
            pre_v31_total_supply: pre_v31_total_supply.to_string(),
        },
    )
    .await?;

    logger::success("set-zkos-pre-v31-total-supply prepared");
    Ok(())
}
