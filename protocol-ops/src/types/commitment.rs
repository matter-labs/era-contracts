use std::str::FromStr;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::Display;

use crate::types::VMOption;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Display, ValueEnum)]
#[repr(u8)]
pub enum L2DACommitmentScheme {
    None = 0,
    EmptyNoDA = 1,
    PubdataKeccak256 = 2,
    BlobsAndPubdataKeccak256 = 3,
    BlobsZKSyncOS = 4,
}

impl L2DACommitmentScheme {
    pub fn from_da_and_vm_types(da_type: DAValidatorType, vm_type: VMOption) -> Self {
        match da_type {
            DAValidatorType::Rollup => match vm_type {
                VMOption::EraVM => L2DACommitmentScheme::BlobsAndPubdataKeccak256,
                VMOption::ZKSyncOsVM => L2DACommitmentScheme::BlobsZKSyncOS,
            },
            DAValidatorType::Avail | DAValidatorType::Eigen => {
                L2DACommitmentScheme::PubdataKeccak256
            }
            DAValidatorType::NoDA => L2DACommitmentScheme::EmptyNoDA,
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
