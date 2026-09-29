use anyhow::Result;
use clap::Parser;
use k256::ecdsa::SigningKey;
use sha2::{Digest as _, Sha256};
use sha3::Keccak256;

/// Ecosystem-level roles (shared across all chains).
const ECOSYSTEM_ROLES: &[&str] = &["deployer", "governor", "token_multiplier_setter", "owner"];

/// Per-chain roles (unique to each chain).
const CHAIN_ROLES: &[&str] = &[
    "operator",
    "blob_operator",
    "commit_operator",
    "prove_operator",
    "execute_operator",
    "fee_account",
    "owner",
];

#[derive(Parser, Debug)]
#[command(
    name = "wallets-gen",
    about = "Generate wallets.yaml with ecosystem and per-chain keys"
)]
struct Opt {
    /// Comma-separated chain names (e.g. "gateway,gateway_settling_a,gateway_settling_b,l1_settling").
    #[arg(long, value_delimiter = ',')]
    chains: Vec<String>,

    /// Ecosystem seed prefix (default: "ecosystem").
    #[arg(long, default_value = "ecosystem")]
    ecosystem_seed: String,

    /// Output file path (default: wallets.yaml in current directory)
    #[arg(long, default_value = "wallets.yaml")]
    output: String,
}

#[derive(serde::Serialize)]
struct Wallet {
    address: String,
    private_key: String,
}

fn private_key_from_seed(seed: &str) -> [u8; 32] {
    Sha256::digest(seed.as_bytes()).into()
}

fn wallet_from_seed(seed: &str) -> Result<Wallet> {
    let sk_bytes = private_key_from_seed(seed);
    let signing_key = SigningKey::from_bytes((&sk_bytes).into())?;
    let verifying_key = signing_key.verifying_key();
    let public_key = verifying_key.to_encoded_point(false);
    let public_key_bytes = &public_key.as_bytes()[1..];

    let address_hash: [u8; 32] = Keccak256::digest(public_key_bytes).into();
    let address = &address_hash[12..];

    Ok(Wallet {
        address: format!("0x{}", hex::encode(address)),
        private_key: format!("0x{}", hex::encode(sk_bytes)),
    })
}

fn write_wallet(yaml: &mut String, indent: &str, role: &str, wallet: &Wallet) {
    yaml.push_str(&format!(
        "{indent}{role}:\n{indent}  address: {}\n{indent}  private_key: {}\n",
        wallet.address, wallet.private_key
    ));
}

fn main() -> Result<()> {
    let opt = Opt::parse();

    if opt.chains.is_empty() {
        anyhow::bail!("At least one chain name is required via --chains");
    }

    let mut yaml = String::new();

    // Ecosystem keys
    yaml.push_str("ecosystem:\n");
    for role in ECOSYSTEM_ROLES {
        let seed = format!("{role}|{}", opt.ecosystem_seed);
        let wallet = wallet_from_seed(&seed)?;
        write_wallet(&mut yaml, "  ", role, &wallet);
    }

    // Per-chain keys
    for chain in &opt.chains {
        yaml.push_str(&format!("{chain}:\n"));
        for role in CHAIN_ROLES {
            let seed = format!("{role}|{chain}");
            let wallet = wallet_from_seed(&seed)?;
            write_wallet(&mut yaml, "  ", role, &wallet);
        }
    }

    if let Some(parent) = std::path::Path::new(&opt.output).parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(&opt.output, &yaml)?;

    println!("Wallets written to: {}", opt.output);
    Ok(())
}
