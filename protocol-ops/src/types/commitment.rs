use std::str::FromStr;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::Display;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, ValueEnum)]
pub enum DAValidatorType {
    /// Commits and publishes the whole pubdata.
    #[default]
    Rollup,
    /// Commits only the mandatory L2->L1 log region — the interop commitment tree leaves included
    /// — and drops the state diffs and message preimages. Delivered through blobs like a rollup's
    /// unless `--l2-da-commitment-scheme` says otherwise.
    LogsOnlyValidium,
    /// Hands the full pubdata to an external DA layer.
    Avail,
    /// Hands the full pubdata to an external DA layer.
    Eigen,
}

impl DAValidatorType {
    pub fn to_u8(self) -> u8 {
        match self {
            DAValidatorType::Rollup => 0,
            DAValidatorType::LogsOnlyValidium => 1,
            DAValidatorType::Avail => 2,
            DAValidatorType::Eigen => 3,
        }
    }
}

/// How much pubdata a ZKsync OS chain's batches commit to — the second DA axis, free to combine
/// with any [`DAValidatorType`]. Part of the batch public input via the chain config hash, so the
/// value set on L1 must match the one the chain's server/prover runs with
/// (`ChainConfig::with_pubdata_content` on ZKsync OS).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, Display, ValueEnum,
)]
#[repr(u8)]
pub enum PubdataContent {
    /// The whole pubdata is committed and must be published. What a fresh chain starts with, and the
    /// only value a permanent rollup may have.
    #[default]
    FullPubdata = 0,
    /// Only the mandatory L2->L1 log region (including the interop-commitment tree leaves) is
    /// committed; state diffs and message preimages are published at the operator's discretion.
    LogsOnly = 1,
}

impl PubdataContent {
    /// The default for a chain's DA mode, used when the caller names no content of its own.
    ///
    /// A validium commits the log region and nothing else; everything else commits the whole
    /// pubdata. This is a default: `--pubdata-content` overrides it, and every combination with a
    /// delivery scheme is expressible.
    ///
    pub fn from_da_type(da_type: DAValidatorType) -> Self {
        match da_type {
            DAValidatorType::LogsOnlyValidium => PubdataContent::LogsOnly,
            DAValidatorType::Rollup | DAValidatorType::Avail | DAValidatorType::Eigen => {
                PubdataContent::FullPubdata
            }
        }
    }

    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

/// How a chain's committed pubdata is delivered to L1 — the on-chain `L2DACommitmentScheme`, and
/// the second DA axis.
///
/// Callers normally never name a variant: [`Self::from_da_type`] derives blobs for every
/// [`DAValidatorType`] on ZKsync OS. Naming one is how a chain gets a different delivery than its
/// kind implies: commit-tx calldata (`blobs-and-pubdata-keccak256`), nothing at all
/// (`discouraged-empty-no-da`), or the scheme a gateway-settling chain needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Display, ValueEnum)]
#[repr(u8)]
pub enum L2DACommitmentScheme {
    None = 0,
    /// Nothing is delivered: the batch commits the empty no-DA scheme.
    ///
    /// Discouraged, hence the spelling. Whatever the chain committed is then unavailable from L1,
    /// its interop commitment tree leaves included, so the chain cannot take part in interop.
    #[value(
        name = "discouraged-empty-no-da",
        alias = "empty-no-da",
        alias = "empty-no-d-a"
    )]
    EmptyNoDA = 1,
    PubdataKeccak256 = 2,
    BlobsAndPubdataKeccak256 = 3,
    #[value(name = "blobs-zksync-os", alias = "blobs-z-k-sync-os")]
    BlobsZKSyncOS = 4,
}

impl L2DACommitmentScheme {
    /// Resolve the L2 DA commitment scheme for a ZKsync OS chain that settles
    /// **directly on L1**.
    ///
    /// Do NOT use this for gateway-settling chains — use
    /// [`Self::for_gateway_settling`] instead.  Gateway-settling chains relay
    /// their pubdata through the gateway and the server encodes them with
    /// `pubdata_mode = RelayedL2Calldata`, which maps to
    /// `BlobsAndPubdataKeccak256` (scheme 3).  Passing
    /// `BlobsZKSyncOS` (scheme 4) from this function into
    /// `set_da_validator_pair` causes `MismatchL2DACommitmentScheme` errors on
    /// every batch commit.
    pub fn from_da_type(da_type: DAValidatorType) -> Self {
        match da_type {
            DAValidatorType::Rollup => L2DACommitmentScheme::BlobsZKSyncOS,
            DAValidatorType::Avail | DAValidatorType::Eigen => {
                L2DACommitmentScheme::PubdataKeccak256
            }
            // A logs-only validium delivers less pubdata, not none: the log region — with the
            // interop commitment tree leaves in it — reaches L1 through the same blobs a rollup
            // uses, unless the caller names another scheme.
            DAValidatorType::LogsOnlyValidium => L2DACommitmentScheme::BlobsZKSyncOS,
        }
    }

    /// Resolve the L2 DA commitment scheme for a chain that settles **on a
    /// gateway** (gateway-settling chain).
    ///
    /// Gateway-settling chains relay their pubdata through the gateway L2.
    /// The ZKsync OS server uses `pubdata_mode = RelayedL2Calldata` for these
    /// chains, which maps to `BlobsAndPubdataKeccak256` (scheme 3).
    /// [`Self::from_da_type`] would return `BlobsZKSyncOS` (scheme 4),
    /// which is incorrect for this case.
    pub fn for_gateway_settling(da_type: DAValidatorType) -> Self {
        match da_type {
            DAValidatorType::Rollup => L2DACommitmentScheme::BlobsAndPubdataKeccak256,
            DAValidatorType::Avail | DAValidatorType::Eigen => {
                L2DACommitmentScheme::PubdataKeccak256
            }
            DAValidatorType::LogsOnlyValidium => L2DACommitmentScheme::EmptyNoDA,
        }
    }
}

impl TryFrom<u8> for L2DACommitmentScheme {
    type Error = &'static str;
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(L2DACommitmentScheme::None),
            1 => Ok(L2DACommitmentScheme::EmptyNoDA),
            2 => Ok(L2DACommitmentScheme::PubdataKeccak256),
            3 => Ok(L2DACommitmentScheme::BlobsAndPubdataKeccak256),
            4 => Ok(L2DACommitmentScheme::BlobsZKSyncOS),
            _ => Err("Invalid L2DACommitmentScheme value"),
        }
    }
}

impl FromStr for L2DACommitmentScheme {
    type Err = &'static str;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "None" => Ok(Self::None),
            "EmptyNoDA" => Ok(Self::EmptyNoDA),
            "PubdataKeccak256" => Ok(Self::PubdataKeccak256),
            "BlobsAndPubdataKeccak256" => Ok(Self::BlobsAndPubdataKeccak256),
            "BlobsZKSyncOS" => Ok(Self::BlobsZKSyncOS),
            _ => Err(
                "Incorrect L2 DA commitment scheme; expected one of `None`, `EmptyNoDA`, `PubdataKeccak256`, `BlobsAndPubdataKeccak256`, `BlobsZKSyncOS`",
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a chain is (`DAValidatorType`) fixes how much pubdata it commits; how that pubdata is
    /// delivered is the other axis, and every kind defaults to blobs on ZKsync OS.
    #[test]
    fn zksync_os_defaults_to_blobs_whatever_the_chain_is() {
        for da in [DAValidatorType::Rollup, DAValidatorType::LogsOnlyValidium] {
            assert_eq!(
                L2DACommitmentScheme::from_da_type(da),
                L2DACommitmentScheme::BlobsZKSyncOS
            );
        }
        assert_eq!(
            PubdataContent::from_da_type(DAValidatorType::Rollup),
            PubdataContent::FullPubdata
        );
        assert_eq!(
            PubdataContent::from_da_type(DAValidatorType::LogsOnlyValidium),
            PubdataContent::LogsOnly
        );
    }

    /// Delivering nothing is a scheme an operator has to ask for by name, and the name says so.
    #[test]
    fn no_da_delivery_is_spelled_out_as_discouraged() {
        assert_eq!(
            <L2DACommitmentScheme as ValueEnum>::from_str("discouraged-empty-no-da", false)
                .unwrap(),
            L2DACommitmentScheme::EmptyNoDA
        );
        assert_eq!(
            <L2DACommitmentScheme as ValueEnum>::from_str("empty-no-da", false).unwrap(),
            L2DACommitmentScheme::EmptyNoDA
        );
    }
}
