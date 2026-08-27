use std::str::FromStr;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::Display;

use crate::types::VMOption;

/// The kind of chain being created, named after what it does with its pubdata.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, ValueEnum)]
pub enum DAValidatorType {
    /// Publishes the whole pubdata on L1.
    #[default]
    Rollup,
    /// Publishes only the mandatory L2->L1 log region on L1 — including the interop commitment tree
    /// leaves, which is what keeps such a chain interop-capable — and drops the state diffs and the
    /// message preimages. On ZKsync OS that region still goes into blobs, so the chain runs the same
    /// DA validator a rollup does and differs from it only in `PubdataContent`; the Era VM has no
    /// pubdata-content axis, so there this is the classic no-DA validium (`EmptyNoDA`).
    #[value(alias = "no-da")]
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

/// Which part of the pubdata a ZKsync OS chain's batches commit to. Orthogonal to
/// [`L2DACommitmentScheme`] (the publishing *mechanism*) and part of the batch public input via the
/// chain config hash, so the value set on L1 must match the one the chain's server/prover runs with
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
    /// The pubdata content implied by a chain's DA mode.
    ///
    /// A rollup commits and publishes everything; a [`DAValidatorType::LogsOnlyValidium`] commits
    /// exactly the region its name says. A custom-DA chain (`Avail`/`Eigen`) commits
    /// `keccak(pubdata)` over the *full* pubdata it hands to its DA layer, so it stays `FullPubdata`.
    ///
    /// Era chains have no such setting (`Admin.setPubdataContent` is ZKsync OS only), hence the `Option`.
    pub fn from_da_and_vm_types(da_type: DAValidatorType, vm_type: VMOption) -> Option<Self> {
        if !vm_type.is_zksync_os() {
            return None;
        }
        Some(match da_type {
            DAValidatorType::LogsOnlyValidium => PubdataContent::LogsOnly,
            DAValidatorType::Rollup | DAValidatorType::Avail | DAValidatorType::Eigen => {
                PubdataContent::FullPubdata
            }
        })
    }

    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

/// The mechanism a chain's batches commit their pubdata with — the on-chain `L2DACommitmentScheme`.
///
/// Callers normally never name a variant: [`Self::from_da_and_vm_types`] derives it from what the
/// chain does with its pubdata plus the VM it runs. The CLI spellings below exist for the few places
/// that still need to override the derived value (a gateway-settling chain).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Display, ValueEnum)]
#[repr(u8)]
pub enum L2DACommitmentScheme {
    None = 0,
    #[value(name = "empty-no-da", alias = "empty-no-d-a")]
    EmptyNoDA = 1,
    PubdataKeccak256 = 2,
    BlobsAndPubdataKeccak256 = 3,
    #[value(name = "blobs-zksync-os", alias = "blobs-z-k-sync-os")]
    BlobsZKSyncOS = 4,
}

impl L2DACommitmentScheme {
    /// Resolve the L2 DA commitment scheme for a chain that settles **directly
    /// on L1**.
    ///
    /// Do NOT use this for gateway-settling chains — use
    /// [`Self::for_gateway_settling`] instead.  Gateway-settling chains relay
    /// their pubdata through the gateway and the server encodes them with
    /// `pubdata_mode = RelayedL2Calldata`, which maps to
    /// `BlobsAndPubdataKeccak256` (scheme 3) regardless of VM type.  Passing
    /// `BlobsZKSyncOS` (scheme 4) from this function into
    /// `set_da_validator_pair` causes `MismatchL2DACommitmentScheme` errors on
    /// every batch commit.
    pub fn from_da_and_vm_types(da_type: DAValidatorType, vm_type: VMOption) -> Self {
        match da_type {
            DAValidatorType::Rollup => match vm_type {
                VMOption::EraVM => L2DACommitmentScheme::BlobsAndPubdataKeccak256,
                VMOption::ZKSyncOsVM => L2DACommitmentScheme::BlobsZKSyncOS,
            },
            DAValidatorType::Avail | DAValidatorType::Eigen => {
                L2DACommitmentScheme::PubdataKeccak256
            }
            // A logs-only validium publishes less pubdata, not none: the L2->L1 log region — with the
            // interop commitment tree leaves in it — still reaches L1 through the same blob mechanism
            // a rollup uses. The DA *mechanism* is therefore identical to a rollup's and only
            // `PubdataContent` differs, so the chain runs the ZKsync OS blobs L1 DA validator. The
            // Era VM has no pubdata-content axis, so there this stays the classic no-DA validium.
            DAValidatorType::LogsOnlyValidium => match vm_type {
                VMOption::EraVM => L2DACommitmentScheme::EmptyNoDA,
                VMOption::ZKSyncOsVM => L2DACommitmentScheme::BlobsZKSyncOS,
            },
        }
    }

    /// Resolve the L2 DA commitment scheme for a chain that settles **on a
    /// gateway** (gateway-settling chain).
    ///
    /// Gateway-settling chains relay their pubdata through the gateway L2.
    /// The ZKsync OS server uses `pubdata_mode = RelayedL2Calldata` for these
    /// chains, which maps to `BlobsAndPubdataKeccak256` (scheme 3).
    /// [`Self::from_da_and_vm_types`] would return `BlobsZKSyncOS` (scheme 4)
    /// for ZKsync OS chains, which is incorrect for this case.
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

    /// A logs-only validium keeps the rollup's DA *mechanism* (blobs) and only narrows the pubdata
    /// *content*, so that its interop commitment leaves stay on L1.
    #[test]
    fn zksync_os_validium_publishes_the_log_region_through_blobs() {
        assert_eq!(
            L2DACommitmentScheme::from_da_and_vm_types(
                DAValidatorType::LogsOnlyValidium,
                VMOption::ZKSyncOsVM
            ),
            L2DACommitmentScheme::BlobsZKSyncOS
        );
        assert_eq!(
            PubdataContent::from_da_and_vm_types(
                DAValidatorType::LogsOnlyValidium,
                VMOption::ZKSyncOsVM
            ),
            Some(PubdataContent::LogsOnly)
        );
    }

    #[test]
    fn zksync_os_rollup_publishes_everything_through_blobs() {
        assert_eq!(
            L2DACommitmentScheme::from_da_and_vm_types(
                DAValidatorType::Rollup,
                VMOption::ZKSyncOsVM
            ),
            L2DACommitmentScheme::BlobsZKSyncOS
        );
        assert_eq!(
            PubdataContent::from_da_and_vm_types(DAValidatorType::Rollup, VMOption::ZKSyncOsVM),
            Some(PubdataContent::FullPubdata)
        );
    }

    /// Era validiums are unchanged: no DA commitment at all, and no pubdata content setting.
    #[test]
    fn era_validium_keeps_the_empty_no_da_scheme() {
        assert_eq!(
            L2DACommitmentScheme::from_da_and_vm_types(
                DAValidatorType::LogsOnlyValidium,
                VMOption::EraVM
            ),
            L2DACommitmentScheme::EmptyNoDA
        );
        assert_eq!(
            PubdataContent::from_da_and_vm_types(
                DAValidatorType::LogsOnlyValidium,
                VMOption::EraVM
            ),
            None
        );
    }
}
