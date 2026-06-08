use alloy::network::Ethereum;
use alloy::providers::{Provider, ProviderBuilder, RootProvider};
use anyhow::Context;
use tokio::task::block_in_place;

pub type AlloyProvider = RootProvider<Ethereum>;

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
