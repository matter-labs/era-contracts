use alloy::primitives::{Address, B256};
use alloy::signers::local::{coins_bip39::English, MnemonicBuilder, PrivateKeySigner};
use anyhow::Context as _;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct WalletSerde {
    pub address: Address,
    pub private_key: Option<B256>,
}

#[derive(Debug, Clone)]
pub struct Wallet {
    pub address: Address,
    pub private_key: Option<PrivateKeySigner>,
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
                let signer = PrivateKeySigner::from_bytes(&k).map_err(serde::de::Error::custom)?;
                if signer.address() != x.address {
                    return Err(serde::de::Error::custom(format!(
                        "address does not match private key: got address {:#x}, want {:#x}",
                        x.address,
                        signer.address(),
                    )));
                }
                Self::new(signer)
            }
        })
    }
}

impl Serialize for Wallet {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        WalletSerde {
            address: self.address,
            private_key: self.private_key_b256(),
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
    pub fn parse(private_key: Option<B256>, address: Option<Address>) -> anyhow::Result<Self> {
        if let Some(pk) = private_key {
            let signer = PrivateKeySigner::from_bytes(&pk)
                .map_err(|e| anyhow::anyhow!("invalid private key: {}", e))?;
            if let Some(addr) = address {
                if addr != signer.address() {
                    anyhow::bail!(
                        "address {:#x} does not match private key (derives {:#x})",
                        addr,
                        signer.address()
                    );
                }
            }
            Ok(Self::new(signer))
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
        private_key: Option<B256>,
        fallback: &Wallet,
    ) -> anyhow::Result<Self> {
        match (addr, private_key) {
            (addr, Some(pk)) => {
                let signer = PrivateKeySigner::from_bytes(&pk)
                    .map_err(|e| anyhow::anyhow!("invalid private key: {}", e))?;
                if let Some(addr) = addr {
                    anyhow::ensure!(
                        signer.address() == addr,
                        "private key derives {:#x} but address is {:#x}",
                        signer.address(),
                        addr
                    );
                }
                Ok(Self::new(signer))
            }
            (Some(addr), None) => Ok(Self {
                address: addr,
                private_key: None,
            }),
            (None, None) => Ok(fallback.clone()),
        }
    }

    pub fn private_key_b256(&self) -> Option<B256> {
        self.private_key.as_ref().map(|k| k.to_bytes())
    }

    pub fn new(private_key: PrivateKeySigner) -> Self {
        Self {
            address: private_key.address(),
            private_key: Some(private_key),
        }
    }

    pub fn from_mnemonic(mnemonic: &str, base_path: &str, index: u32) -> anyhow::Result<Self> {
        let signer = MnemonicBuilder::<English>::default()
            .phrase(mnemonic)
            .derivation_path(format!("{}/{}", base_path, index))?
            .build()?;
        Ok(Self::new(signer))
    }

    pub fn empty() -> Self {
        Self {
            address: Address::ZERO,
            private_key: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Wallets YAML schema (used by `apply` to load operator keys for each chain)
// ---------------------------------------------------------------------------

#[derive(Debug, serde::Deserialize)]
pub struct SimpleWallet {
    pub address: String,
}

#[derive(serde::Deserialize)]
pub struct ChainWallets {
    pub owner: SimpleWallet,
    pub operator_commit_sk: String,
    pub operator_prove_sk: String,
    pub operator_execute_sk: String,
}

impl std::fmt::Debug for ChainWallets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChainWallets")
            .field("owner", &self.owner)
            .field("operator_commit_sk", &"[REDACTED]")
            .field("operator_prove_sk", &"[REDACTED]")
            .field("operator_execute_sk", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct WalletsYaml {
    #[allow(dead_code)]
    pub ecosystem: serde_yaml::Value,
    #[serde(flatten)]
    pub chains: std::collections::BTreeMap<String, ChainWallets>,
}

pub fn load_wallets(path: &std::path::PathBuf) -> anyhow::Result<WalletsYaml> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("reading wallets file {}", path.display()))?;
    serde_yaml::from_str(&content)
        .with_context(|| format!("parsing wallets file {}", path.display()))
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
        "0xa61464658AfeAf65CccaaFD3a512b69A83B77618"
            .parse::<alloy::primitives::Address>()
            .unwrap()
    );
}
