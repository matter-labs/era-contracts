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

use anyhow::Context;
use clap::Parser;
use ethers::middleware::SignerMiddleware;
use ethers::providers::{Http, Middleware, Provider};
use ethers::signers::{LocalWallet, Signer};
use ethers::types::{Address, BlockNumber, TransactionRequest, H256, U256};
use serde::{Deserialize, Serialize};

use crate::abi::IGWAssetTrackerAbi;
use crate::commands::output::write_output_if_requested;
use crate::common::logger;
use crate::common::SharedRunArgs;

/// `GW_ASSET_TRACKER_ADDR` from `contracts/common/l2-helpers/L2ContractAddresses.sol`
/// (`BUILT_IN_CONTRACTS_OFFSET + 0x10 = 0x10000 + 0x10 = 0x10010`).
const GW_ASSET_TRACKER_ADDR_HEX: &str = "0x0000000000000000000000000000000000010010";

/// Cap per-tx gas at 8M — `setSettlementFeePayerAgreement` is a single
/// storage write so this is comfortably above what it needs but well under
/// any reasonable block gas limit.
const GAS_LIMIT: u64 = 8_000_000;

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
    let pk_h256 = H256::from_str(args.private_key.as_str())
        .context("invalid --private-key (expected 0x-prefixed hex)")?;
    let wallet = LocalWallet::from_bytes(pk_h256.as_bytes())
        .context("invalid --private-key (failed to construct signer)")?;
    let payer = Signer::address(&wallet);

    let provider = Provider::<Http>::try_from(args.gw_rpc_url.as_str())
        .context("connect Gateway L2 provider")?
        .interval(Duration::from_millis(50));
    let gw_chain_id = provider
        .get_chainid()
        .await
        .context("eth_chainId on Gateway RPC")?
        .as_u64();
    let client = SignerMiddleware::new(provider, wallet.with_chain_id(gw_chain_id));

    let asset_tracker_addr: Address = GW_ASSET_TRACKER_ADDR_HEX.parse().unwrap();
    let agreed = !args.revoke;
    let calldata = IGWAssetTrackerAbi::new(asset_tracker_addr, client.provider().clone().into())
        .set_settlement_fee_payer_agreement(args.chain_id.into(), agreed)
        .calldata()
        .ok_or_else(|| anyhow::anyhow!("failed to encode setSettlementFeePayerAgreement calldata"))?;

    logger::step(format!(
        "{} settlement-fee-payer agreement for chain {} on GW (chainId {})",
        if agreed { "Setting" } else { "Revoking" },
        args.chain_id,
        gw_chain_id,
    ));
    logger::info(format!("Payer (msg.sender):  {payer:#x}"));
    logger::info(format!("GWAssetTracker:      {asset_tracker_addr:#x}"));

    let nonce = client
        .get_transaction_count(payer, Some(BlockNumber::Pending.into()))
        .await
        .context("eth_getTransactionCount(pending)")?;

    let req = TransactionRequest::new()
        .from(payer)
        .to(asset_tracker_addr)
        .data(calldata)
        .value(U256::zero())
        .chain_id(gw_chain_id)
        .gas(GAS_LIMIT)
        .nonce(nonce);

    let pending = client
        .send_transaction(req, None)
        .await
        .context("eth_sendTransaction for setSettlementFeePayerAgreement")?;
    let tx_hash = pending.tx_hash();
    let receipt = pending
        .await
        .context("await receipt for setSettlementFeePayerAgreement")?
        .ok_or_else(|| anyhow::anyhow!("no receipt for setSettlementFeePayerAgreement"))?;
    let status = receipt.status.unwrap_or_default();
    anyhow::ensure!(
        status == 1.into(),
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
