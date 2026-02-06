use std::str::FromStr;

use clap::ValueEnum;
use ethers::{types::Address};
use serde::{Deserialize, Serialize};
use strum::{Display, EnumIter};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, EnumIter, Display)]
pub enum L1BatchCommitmentMode {
    #[default]
    Rollup,
    Validium,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, ValueEnum)]
pub enum DAValidatorType {
    #[default]
    Rollup,
    NoDA,
    Avail,
    Eigen,
}

impl DAValidatorType {
    pub fn to_u8(&self) -> u8 {
        match self {
            DAValidatorType::Rollup => 0,
            DAValidatorType::NoDA => 1,
            DAValidatorType::Avail => 2,
            DAValidatorType::Eigen => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Display)]
#[repr(u8)]
pub enum L2DACommitmentScheme {
    None = 0,
    EmptyNoDA = 1,
    PubdataKeccak256 = 2,
    BlobsAndPubdataKeccak256 = 3,
    BlobsZKSyncOS = 4,
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
            _ => Err("Incorrect L2 DA commitment scheme; expected one of `None`, `EmptyNoDA`, `PubdataKeccak256`, `BlobsAndPubdataKeccak256`"),
        }
    }
}

#[derive(Copy, Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum L2PubdataValidator {
    Address(Address),
    CommitmentScheme(L2DACommitmentScheme),
}

impl TryFrom<(Option<Address>, Option<L2DACommitmentScheme>)> for L2PubdataValidator {
    type Error = anyhow::Error;

    fn try_from(
        value: (Option<Address>, Option<L2DACommitmentScheme>),
    ) -> Result<Self, Self::Error> {
        match value {
            (None, Some(scheme)) => Ok(L2PubdataValidator::CommitmentScheme(scheme)),
            (Some(address), None) => Ok(L2PubdataValidator::Address(address)),
            (Some(_), Some(_)) => anyhow::bail!(
                "Address and L2DACommitmentScheme are specified, should be chosen only one"
            ),
            (None, None) => anyhow::bail!(
                "Address and L2DACommitmentScheme are not specified, should be chosen at least one"
            ),
        }
    }
}

impl L2PubdataValidator {
    pub fn l2_da_validator(&self) -> Option<Address> {
        match self {
            L2PubdataValidator::Address(addr) => Some(*addr),
            L2PubdataValidator::CommitmentScheme(_) => None,
        }
    }

    pub fn l2_da_commitment_scheme(&self) -> Option<L2DACommitmentScheme> {
        match self {
            L2PubdataValidator::Address(_) => None,
            L2PubdataValidator::CommitmentScheme(scheme) => Some(*scheme),
        }
    }
}
