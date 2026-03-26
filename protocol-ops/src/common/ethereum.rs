use std::sync::Arc;

use ethers::{
    core::k256::ecdsa::SigningKey,
    middleware::MiddlewareBuilder,
    prelude::{Http, LocalWallet, Provider, Signer, SignerMiddleware},
};

pub fn get_ethers_provider(url: &str) -> anyhow::Result<Arc<Provider<Http>>> {
    let provider = match Provider::<Http>::try_from(url) {
        Ok(provider) => provider,
        Err(err) => {
            anyhow::bail!("Connection error: {:#?}", err);
        }
    };
    Ok(Arc::new(provider))
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
