use std::str::FromStr;
use std::sync::Arc;

use anyhow::Context;
use ethers::{
    middleware::Middleware as _,
    prelude::{Http, Provider},
    types::H256,
};
use tokio::task::block_in_place;

/// Convert a hex-string Merkle proof (as returned by JSON-RPC `zks_*` proof
/// methods) into the `Vec<H256>` form ethers tokenizes as `bytes32[]`. Pass
/// `Vec<String>` directly into `with_script_call(...)` and ethers encodes it
/// as `string[]`, which is silently mis-encoded against the contract ABI.
pub fn parse_merkle_proof<S: AsRef<str>>(proof: &[S]) -> anyhow::Result<Vec<H256>> {
    proof
        .iter()
        .map(|s| {
            let s = s.as_ref();
            H256::from_str(s.trim_start_matches("0x"))
                .with_context(|| format!("invalid merkle proof element: {s}"))
        })
        .collect()
}

pub fn get_ethers_provider(url: &str) -> anyhow::Result<Arc<Provider<Http>>> {
    let provider = match Provider::<Http>::try_from(url) {
        Ok(provider) => provider,
        Err(err) => {
            anyhow::bail!("Connection error: {:#?}", err);
        }
    };
    Ok(Arc::new(provider))
}

pub fn query_chain_id_sync(rpc_url: &str) -> anyhow::Result<u64> {
    let provider = get_ethers_provider(rpc_url)?;
    let fut = provider.get_chainid();
    let id = if let Ok(handle) = tokio::runtime::Handle::try_current() {
        block_in_place(|| handle.block_on(fut))?
    } else {
        tokio::runtime::Runtime::new()
            .context("failed to create Tokio runtime")?
            .block_on(fut)?
    };
    Ok(id.as_u64())
}
