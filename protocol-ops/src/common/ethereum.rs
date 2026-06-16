use std::str::FromStr;

use alloy::network::Ethereum;
use alloy::primitives::B256;
use alloy::providers::{Provider, ProviderBuilder, RootProvider};
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
