#[cfg(test)]
use crate::common::addresses::DEFAULT_TEST_WALLET_ADDRESS;
use anyhow::Context as _;
#[cfg(test)]
use ethers::signers::{coins_bip39::English, MnemonicBuilder};
use ethers::{
    signers::{LocalWallet, Signer},
    types::{Address, H256},
};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct WalletSerde {
    pub address: Address,
    pub private_key: Option<H256>,
}

#[derive(Debug, Clone)]
pub struct Wallet {
    pub address: Address,
    pub private_key: Option<LocalWallet>,
}

impl<'de> Deserialize<'de> for Wallet {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let x = WalletSerde::deserialize(d)?;
        Ok(match x.private_key {
            None => Self {
                address: x.address,
                private_key: None,
            },
            Some(k) => {
                let k = LocalWallet::from_bytes(k.as_bytes()).map_err(serde::de::Error::custom)?;
                if k.address() != x.address {
                    return Err(serde::de::Error::custom(format!(
                        "address does not match private key: got address {:#x}, want {:#x}",
                        x.address,
                        k.address(),
                    )));
                }
                Self::new(k)
            }
        })
    }
}

impl Serialize for Wallet {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        WalletSerde {
            address: self.address,
            private_key: self.private_key_h256(),
        }
        .serialize(s)
    }
}

impl Wallet {
    /// Parse a wallet from optional CLI `--private-key` / `--sender` args.
    ///
    /// - If `private_key`: derive address, validate against `address` if provided.
    /// - If `address` only: return address-only wallet (needs `--unlocked` at node).
    /// - If neither: bail.
    pub fn parse(private_key: Option<H256>, address: Option<Address>) -> anyhow::Result<Self> {
        if let Some(pk) = private_key {
            let wallet = LocalWallet::from_bytes(pk.as_bytes())
                .map_err(|e| anyhow::anyhow!("invalid private key: {}", e))?;
            if let Some(addr) = address {
                if addr != wallet.address() {
                    anyhow::bail!(
                        "address {:#x} does not match private key (derives {:#x})",
                        addr,
                        wallet.address()
                    );
                }
            }
            Ok(Self::new(wallet))
        } else if let Some(addr) = address {
            Ok(Self {
                address: addr,
                private_key: None,
            })
        } else {
            anyhow::bail!("either --private-key or --sender must be provided")
        }
    }

    /// Resolve a wallet from optional address + key, falling back to `fallback` if neither given.
    ///
    /// - Both `addr` and `pk`: validate pk derives addr, return keyed wallet.
    /// - Only `pk`: derive address from pk.
    /// - Only `addr`: return address-only wallet (unlocked / impersonation).
    /// - Neither: clone `fallback`.
    pub fn resolve(
        addr: Option<Address>,
        private_key: Option<H256>,
        fallback: &Wallet,
    ) -> anyhow::Result<Self> {
        match (addr, private_key) {
            (addr, Some(pk)) => {
                let wallet = LocalWallet::from_bytes(pk.as_bytes())
                    .map_err(|e| anyhow::anyhow!("invalid private key: {}", e))?;
                if let Some(addr) = addr {
                    anyhow::ensure!(
                        wallet.address() == addr,
                        "private key derives {:#x} but address is {:#x}",
                        wallet.address(),
                        addr
                    );
                }
                Ok(Self::new(wallet))
            }
            (Some(addr), None) => Ok(Self {
                address: addr,
                private_key: None,
            }),
            (None, None) => Ok(fallback.clone()),
        }
    }

    pub fn private_key_h256(&self) -> Option<H256> {
        self.private_key
            .as_ref()
            .map(|k| parse_h256(&k.signer().to_bytes()).unwrap())
    }

    pub fn new(private_key: LocalWallet) -> Self {
        Self {
            address: private_key.address(),
            private_key: Some(private_key),
        }
    }

    #[cfg(test)]
    pub fn from_mnemonic(mnemonic: &str, base_path: &str, index: u32) -> anyhow::Result<Self> {
        let wallet = MnemonicBuilder::<English>::default()
            .phrase(mnemonic)
            .derivation_path(&format!("{}/{}", base_path, index))?
            .build()?;
        Ok(Self::new(wallet))
    }
}

/// Parses H256 from a slice of bytes.
pub fn parse_h256(bytes: &[u8]) -> anyhow::Result<H256> {
    Ok(<[u8; 32]>::try_from(bytes).context("invalid size")?.into())
}

#[test]
fn test_load_localhost_wallets() {
    let wallet = Wallet::from_mnemonic(
        "stuff slice staff easily soup parent arm payment cotton trade scatter struggle",
        "m/44'/60'/0'/0",
        1,
    )
    .unwrap();
    assert_eq!(
        wallet.address,
        Address::from_slice(&ethers::utils::hex::decode(DEFAULT_TEST_WALLET_ADDRESS).unwrap())
    );
}
