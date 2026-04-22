//! Wait until a ZKsync chain's pending protocol upgrade has been finalized.
//!
//! Flow:
//!   1. Resolve the chain's ChainTypeManager on the settlement layer (L1 or gateway).
//!   2. Scan for `NewUpgradeCutData(target_protocol_version, ...)` on the CTM and
//!      extract the embedded `L2CanonicalTransaction`.
//!   3. Compute `keccak256(tx.abi_encode())` — the canonical L2 upgrade-tx hash.
//!   4. Poll the chain's L2 RPC for a receipt; once present, the server processed
//!      the upgrade in L2 block N.
//!   5. Poll `eth_getBlockByNumber("finalized")` until the finalized block is
//!      >= N-1 (the batch containing the preceding block is executed on the
//!      settlement layer). In zksync-os, the `"finalized"` tag resolves to
//!      `last_executed_block`.
//!
//! The tool blocks indefinitely until finalization — transient RPC errors are
//! logged and retried. The surrounding workflow is responsible for any upper-bound
//! timeout and for user-facing notifications (Slack etc.).

mod abi;
mod readiness;
mod upgrade;

use std::process::ExitCode;
use std::time::Duration;

use alloy::primitives::{Address, U256};
use alloy::providers::{Provider, ProviderBuilder};
use anyhow::{Context, Result};
use clap::Parser;
use tracing::{info, warn};

use crate::readiness::Readiness;

/// Bit offset of the `minor` field in the packed protocol-version u256.
/// Matches `PACKED_SEMVER_MINOR_OFFSET` in zksync-os-server's ProtocolSemanticVersion.
const PACKED_SEMVER_MINOR_OFFSET: u32 = 32;

/// How far back (in settlement-layer blocks) to scan for `NewUpgradeCutData`.
/// Mirrors zksync-os-server's `UPGRADE_DATA_LOOKBEHIND_BLOCKS`.
const LOOKBACK_BLOCKS: u64 = 2_500_000;

/// How often to re-check readiness.
const POLL_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Parser, Debug)]
#[command(about, version)]
struct Cli {
    /// L2 RPC URL of the chain being upgraded (used for receipt + batch lookups).
    #[arg(long, env = "L2_RPC_URL")]
    l2_rpc_url: String,

    /// Chain ID of the chain being upgraded.
    #[arg(long, env = "CHAIN_ID")]
    chain_id: u64,

    /// RPC URL of the settlement layer where the chain's bridgehub/CTM live.
    /// For direct L1-settling chains this is the L1 RPC; for gateway-settling chains
    /// this is the gateway L2 RPC.
    #[arg(long, env = "SETTLEMENT_RPC_URL")]
    settlement_rpc_url: String,

    /// Bridgehub address on the settlement layer.
    #[arg(long, env = "BRIDGEHUB_ADDRESS")]
    bridgehub_address: Address,

    /// Minor component of the target protocol version (e.g. `31` for `0.31.0`).
    #[arg(long, env = "TARGET_MINOR_VERSION")]
    target_minor_version: u32,

    /// Patch component of the target protocol version (e.g. `0` for `0.31.0`).
    #[arg(long, env = "TARGET_PATCH_VERSION", default_value_t = 0)]
    target_patch_version: u32,

    /// Whether the chain being upgraded is a ZKsync OS chain. Needed for the
    /// v31 upgrade contract's `getL2UpgradeTxData(_, _, zksyncOS, _)` parameter.
    /// We can't reliably query `diamond.getZKsyncOS()` on pre-v31 chains because
    /// the getter isn't always registered on the diamond facets, so we require it
    /// as an explicit flag from the caller. Pass `--zksync-os` (flag) on ZKsync OS
    /// chains; omit it on Era chains.
    #[arg(long, env = "ZKSYNC_OS", action = clap::ArgAction::SetTrue)]
    zksync_os: bool,
}

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    match run().await {
        Ok(()) => ExitCode::from(0),
        Err(err) => {
            warn!(error = ?err, "readiness check aborted");
            ExitCode::from(1)
        }
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();

    let target_protocol_version = pack_protocol_version(cli.target_minor_version, cli.target_patch_version);
    info!(
        minor = cli.target_minor_version,
        patch = cli.target_patch_version,
        packed = %format!("0x{target_protocol_version:x}"),
        "target protocol version"
    );

    let settlement_provider = ProviderBuilder::new()
        .connect_http(
            cli.settlement_rpc_url
                .parse()
                .context("invalid --settlement-rpc-url")?,
        )
        .erased();

    // Step 1-3: find the pending upgrade's canonical L2 tx hash. Static once the
    // upgrade cut is published — the hash never changes.
    let ctm = upgrade::resolve_ctm(&settlement_provider, cli.bridgehub_address, cli.chain_id)
        .await
        .context("resolving ChainTypeManager from bridgehub")?;
    info!(chain_id = cli.chain_id, %ctm, "resolved ChainTypeManager");

    let upgrade_tx_hash = upgrade::find_upgrade_tx_hash(
        &settlement_provider,
        ctm,
        cli.bridgehub_address,
        cli.chain_id,
        cli.zksync_os,
        target_protocol_version,
        LOOKBACK_BLOCKS,
    )
    .await
    .context("locating upgrade tx on settlement layer")?;
    info!(%upgrade_tx_hash, "computed canonical upgrade tx hash");

    // Step 4-5: block until the upgrade is finalized. Transient errors are logged
    // and retried on the next tick — we never give up on our own.
    loop {
        match readiness::check_readiness(&cli.l2_rpc_url, upgrade_tx_hash).await {
            Ok(Readiness::Ready {
                upgrade_block,
                finalized_block,
            }) => {
                info!(
                    %upgrade_tx_hash,
                    upgrade_block,
                    finalized_block,
                    "upgrade finalized"
                );
                return Ok(());
            }
            Ok(Readiness::ServerNotProcessed) => {
                info!("server has not produced a receipt for the upgrade tx yet — waiting");
            }
            Ok(Readiness::NotFinalized {
                upgrade_block,
                finalized_block,
            }) => {
                info!(
                    upgrade_block,
                    finalized_block,
                    "upgrade processed in block {upgrade_block}, but the preceding block is not yet finalized on the settlement layer",
                );
            }
            Err(err) => {
                warn!(error = ?err, "readiness check failed — will retry");
            }
        }

        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Pack `(minor, patch)` into the u256 layout used by `ProtocolSemanticVersion`:
/// `packed = (minor << 32) | patch`. Major is always 0 for ZKsync.
fn pack_protocol_version(minor: u32, patch: u32) -> U256 {
    (U256::from(minor) << PACKED_SEMVER_MINOR_OFFSET) | U256::from(patch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_matches_contract_layout() {
        // 0.31.0 → minor=31 at offset 32, patch=0 → 31 * 2^32
        let packed = pack_protocol_version(31, 0);
        assert_eq!(packed, U256::from(31u64) << 32);

        // 0.31.2 → minor=31 at offset 32, patch=2
        let packed = pack_protocol_version(31, 2);
        assert_eq!(packed, (U256::from(31u64) << 32) | U256::from(2u64));
    }
}
