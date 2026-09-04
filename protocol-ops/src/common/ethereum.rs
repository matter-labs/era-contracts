use std::str::FromStr;

use alloy::network::Ethereum;
use alloy::primitives::B256;
use alloy::providers::{Provider, ProviderBuilder, RootProvider};
use alloy::rpc::client::ClientBuilder;
use alloy::transports::layers::RetryBackoffLayer;
use anyhow::Context;
use tokio::task::block_in_place;

pub type AlloyProvider = RootProvider<Ethereum>;

/// Convert a hex-string Merkle proof (as returned by JSON-RPC `zks_*` proof
/// methods) into the `Vec<B256>` form expected by typed `bytes32[]` calldata
/// encoders.
pub fn parse_merkle_proof<S: AsRef<str>>(proof: &[S]) -> anyhow::Result<Vec<B256>> {
    proof
        .iter()
        .map(|s| {
            let s = s.as_ref();
            B256::from_str(s.trim_start_matches("0x"))
                .with_context(|| format!("invalid merkle proof element: {s}"))
        })
        .collect()
}

pub fn get_provider(url: &str) -> anyhow::Result<AlloyProvider> {
    Ok(ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_http(url.parse().context("invalid RPC URL")?))
}

/// Provider that backs off and retries on HTTP 429 instead of failing the
/// command. Read-heavy flows (contract discovery, log scans, per-address
/// `eth_getCode`) run into hosted-RPC rate limits within a few hundred
/// requests; `compute_units_per_second` also paces the client so it mostly
/// avoids being throttled in the first place.
pub fn get_rate_limited_provider(
    url: &str,
    compute_units_per_second: u64,
) -> anyhow::Result<AlloyProvider> {
    const MAX_RATE_LIMIT_RETRIES: u32 = 10;
    const INITIAL_BACKOFF_MS: u64 = 500;

    let client = ClientBuilder::default()
        .layer(RetryBackoffLayer::new(
            MAX_RATE_LIMIT_RETRIES,
            INITIAL_BACKOFF_MS,
            compute_units_per_second,
        ))
        .http(url.parse().context("invalid RPC URL")?);
    Ok(RootProvider::new(client))
}

pub fn query_chain_id_sync(rpc_url: &str) -> anyhow::Result<u64> {
    let provider = get_provider(rpc_url)?;
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        block_in_place(|| handle.block_on(provider.get_chain_id())).context("eth_chainId")
    } else {
        tokio::runtime::Runtime::new()
            .context("failed to create Tokio runtime")?
            .block_on(provider.get_chain_id())
            .context("eth_chainId")
    }
}
