use std::sync::Arc;

use anyhow::Context;
use ethers::{
    core::k256::ecdsa::SigningKey,
    middleware::{Middleware as _, MiddlewareBuilder},
    prelude::{Http, LocalWallet, Provider, Signer, SignerMiddleware},
};
use tokio::task::block_in_place;

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

pub fn create_ethers_client(
    mut wallet: LocalWallet,
    l1_rpc: String,
    chain_id: Option<u64>,
) -> anyhow::Result<SignerMiddleware<Provider<Http>, ethers::prelude::Wallet<SigningKey>>> {
    if let Some(chain_id) = chain_id {
        wallet = wallet.with_chain_id(chain_id);
    }
    let client = Provider::<Http>::try_from(l1_rpc)?.with_signer(wallet);
    Ok(client)
}
