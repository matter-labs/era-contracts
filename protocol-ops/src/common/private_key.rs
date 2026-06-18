use std::str::FromStr;

use anyhow::Context;
use zeroize::Zeroizing;

/// Thin wrapper around a hex private key string that redacts itself in
/// `Debug` and `Display` output, preventing accidental logging of key material.
/// The inner `String` is zeroed on drop via `Zeroizing`.
///
/// Use `.expose()` to obtain the raw string when you need it for cryptographic
/// operations. Keep the exposed value short-lived; never store it in a struct
/// or pass it across async boundaries.
#[derive(Clone)]
pub struct PrivateKey(Zeroizing<String>);

impl PrivateKey {
    /// Return the raw hex string (with or without `0x` prefix, as supplied by the user).
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("[REDACTED]")
    }
}

impl std::fmt::Display for PrivateKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("[REDACTED]")
    }
}

impl FromStr for PrivateKey {
    type Err = std::convert::Infallible;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self(Zeroizing::new(s.to_string())))
    }
}

/// Derive the Ethereum address from a raw hex private key string.
pub fn pk_to_address(private_key: &str) -> anyhow::Result<alloy::primitives::Address> {
    use alloy::signers::local::PrivateKeySigner;
    let signer: PrivateKeySigner = private_key.parse().context("invalid private key")?;
    Ok(signer.address())
}
