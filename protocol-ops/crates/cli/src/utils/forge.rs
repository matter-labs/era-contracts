use anyhow::Context as _;
use protocol_ops_common::{forge::ForgeScript, wallets::Wallet};

#[derive(Debug)]
pub enum WalletOwner {
    Governor,
    Deployer,
}

pub fn fill_forge_private_key(
    mut forge: ForgeScript,
    wallet: Option<&Wallet>,
    wallet_owner: WalletOwner,
) -> anyhow::Result<ForgeScript> {
    if !forge.wallet_args_passed() {
        forge = forge.with_private_key(
            wallet
                .and_then(|w| w.private_key_h256())
                .context(format!("Wallet private key not set for {wallet_owner:?}"))?,
        );
    }
    Ok(forge)
}
