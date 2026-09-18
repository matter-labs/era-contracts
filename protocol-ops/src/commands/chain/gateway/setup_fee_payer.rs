//! `protocol-ops chain gateway setup-fee-payer` — per-operator opt-in to pay
//! settlement fees for a specific chain on the Gateway.
//!
//! `GWAssetTracker.setSettlementFeePayerAgreement(chainId, agreed)` is keyed
//! by `msg.sender`: whoever sends the tx becomes (or revokes) the agreed
//! payer for that chainId. This command sends that one tx from the
//! configured signer's EOA against the Gateway's L2 RPC. Standalone,
//! independent of the v31 ecosystem flow — chain operators run it
//! themselves before / after their chain migrates to the GW.
//!
//! The fee payer also needs wrapped-ZK approval for `GW_ASSET_TRACKER_ADDR`
//! to actually charge fees; that's a separate ERC20 `approve` and is left
//! to the operator (it's chain-operator-internal accounting, not protocol
//! state that benefits from being templated here).

use std::str::FromStr;
use std::time::Duration;

use alloy::eips::BlockNumberOrTag;
use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::{address, Address, B256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::IGWAssetTrackerAbi;
use crate::common::logger;
use crate::common::output::write_output_if_requested;
use crate::common::SharedRunArgs;

/// `GW_ASSET_TRACKER_ADDR` from `contracts/common/l2-helpers/L2ContractAddresses.sol`
/// (`BUILT_IN_CONTRACTS_OFFSET + 0x10 = 0x10000 + 0x10 = 0x10010`).
const GW_ASSET_TRACKER_ADDR: Address = address!("0x0000000000000000000000000000000000010010");

/// Cap per-tx gas at 8M — `setSettlementFeePayerAgreement` is a single
/// storage write so this is comfortably above what it needs but well under
/// any reasonable block gas limit.
const GAS_LIMIT: u64 = 8_000_000;

/// Receipt polling interval against the Gateway RPC.
const RECEIPT_POLL_INTERVAL_MS: u64 = 50;

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct SetupFeePayerArgs {
    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    /// Gateway L2 RPC URL. The Gateway's `GWAssetTracker` lives at
    /// `GW_ASSET_TRACKER_ADDR` on this chain, so we hit this RPC directly
    /// rather than going through an L1→L2 priority tx.
    #[clap(long)]
    pub gw_rpc_url: String,

    /// Chain ID this agreement applies to. The signer will be marked as the
    /// agreed settlement-fee payer for this chain on the Gateway.
    #[clap(long)]
    pub chain_id: u64,

    /// Set to revoke a previous opt-in instead of adding one.
    #[clap(long, default_value_t = false)]
    pub revoke: bool,

    /// Private key of the EOA that should become / stop being the agreed
    /// fee payer. The agreement is keyed by `msg.sender` so we have to sign
    /// locally from that EOA's key.
    #[clap(long)]
    pub private_key: String,
}

#[derive(Serialize)]
struct SetupFeePayerOutput {
    gw_rpc_url: String,
    chain_id: u64,
    agreed: bool,
    payer: String,
    tx_hash: String,
}

pub async fn run(args: SetupFeePayerArgs) -> anyhow::Result<()> {
    let pk_b256 = B256::from_str(args.private_key.as_str())
        .context("invalid --private-key (expected 0x-prefixed hex)")?;
    let signer = PrivateKeySigner::from_bytes(&pk_b256)
        .context("invalid --private-key (failed to construct signer)")?;
    let payer = signer.address();

    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(
            args.gw_rpc_url
                .parse()
                .context("connect Gateway L2 provider")?,
        );
    provider
        .client()
        .set_poll_interval(Duration::from_millis(RECEIPT_POLL_INTERVAL_MS));
    let gw_chain_id = provider
        .get_chain_id()
        .await
        .context("eth_chainId on Gateway RPC")?;

    let agreed = !args.revoke;
    let calldata = IGWAssetTrackerAbi::new(GW_ASSET_TRACKER_ADDR, provider.clone())
        .setSettlementFeePayerAgreement(U256::from(args.chain_id), agreed)
        .calldata()
        .clone();

    logger::step(format!(
        "{} settlement-fee-payer agreement for chain {} on GW (chainId {})",
        if agreed { "Setting" } else { "Revoking" },
        args.chain_id,
        gw_chain_id,
    ));
    logger::info(format!("Payer (msg.sender):  {payer:#x}"));
    logger::info(format!("GWAssetTracker:      {GW_ASSET_TRACKER_ADDR:#x}"));

    let nonce = provider
        .get_transaction_count(payer)
        .block_id(BlockNumberOrTag::Pending.into())
        .await
        .context("eth_getTransactionCount(pending)")?;
    // Setting `gas_price` explicitly keeps this a legacy (non-EIP-1559) tx,
    // same shape the previous implementation signed.
    let gas_price = provider
        .get_gas_price()
        .await
        .context("eth_gasPrice on Gateway RPC")?;

    let req = TransactionRequest::default()
        .with_from(payer)
        .with_to(GW_ASSET_TRACKER_ADDR)
        .with_input(calldata)
        .with_value(U256::ZERO)
        .with_chain_id(gw_chain_id)
        .with_gas_limit(GAS_LIMIT)
        .with_nonce(nonce)
        .with_gas_price(gas_price);

    let pending = provider
        .send_transaction(req)
        .await
        .context("eth_sendTransaction for setSettlementFeePayerAgreement")?;
    let tx_hash = *pending.tx_hash();
    let receipt = pending
        .get_receipt()
        .await
        .context("await receipt for setSettlementFeePayerAgreement")?;
    anyhow::ensure!(
        receipt.status(),
        "setSettlementFeePayerAgreement reverted (tx {tx_hash:#x})",
    );

    logger::success(format!(
        "Fee-payer agreement {} (tx {tx_hash:#x})",
        if agreed { "set" } else { "revoked" }
    ));

    let payload = SetupFeePayerOutput {
        gw_rpc_url: args.gw_rpc_url.clone(),
        chain_id: args.chain_id,
        agreed,
        payer: format!("{payer:#x}"),
        tx_hash: format!("{tx_hash:#x}"),
    };
    // Reuse the standard --out envelope wrapper. There's no forge runner here
    // so we pass a fresh one constructed off the L1 RPC just to satisfy the
    // helper's signature — the envelope's `runs` field will be empty.
    let runner = crate::common::forge::ForgeRunner::new(&args.shared)?;
    write_output_if_requested(
        "chain.gateway.setup-fee-payer",
        &args.shared,
        &runner,
        &serde_json::json!({}),
        &payload,
    )
    .await?;

    Ok(())
}
