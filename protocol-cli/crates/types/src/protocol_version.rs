use std::{convert::TryInto, fmt, str::FromStr};
use ethers::types::U256;
use serde_with::{DeserializeFromStr, SerializeDisplay};

pub const PACKED_SEMVER_MINOR_OFFSET: u32 = 32;
pub const PACKED_SEMVER_MINOR_MASK: u32 = 0xFFFF;

/// Semantic protocol version.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, SerializeDisplay, DeserializeFromStr, Hash, PartialOrd, Ord,
)]
pub struct ProtocolSemanticVersion {
    pub minor: u32,
    pub patch: u32,
}

impl ProtocolSemanticVersion {
    const MAJOR_VERSION: u8 = 0;

    pub fn new(minor: u32, patch: u32) -> Self {
        Self { minor, patch }
    }

    pub fn try_from_packed(packed: U256) -> Result<Self, String> {
        let minor = ((packed >> U256::from(PACKED_SEMVER_MINOR_OFFSET))
            & U256::from(PACKED_SEMVER_MINOR_MASK))
        .try_into()?;
        let patch = packed.0[0] as u32;
        Ok(Self { minor, patch })
    }

    pub fn pack(&self) -> U256 {
        (U256::from(self.minor as u16) << U256::from(PACKED_SEMVER_MINOR_OFFSET))
            | U256::from(self.patch)
    }
}

impl fmt::Display for ProtocolSemanticVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}.{}.{}",
            Self::MAJOR_VERSION,
            self.minor as u16,
            self.patch
        )
    }
}

// TODO: !!!
impl Default for ProtocolSemanticVersion {
    fn default() -> Self {
        Self { minor: 0, patch: 0 }
    }
}

impl FromStr for ProtocolSemanticVersion {
    type Err = ParseProtocolSemanticVersionError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let parts: Vec<&str> = s.split('.').collect();
        if parts.len() != 3 {
            return Err(ParseProtocolSemanticVersionError::InvalidFormat);
        }

        let major = parts[0]
            .parse::<u16>()
            .map_err(ParseProtocolSemanticVersionError::ParseIntError)?;
        if major != 0 {
            return Err(ParseProtocolSemanticVersionError::NonZeroMajorVersion);
        }

        let minor = parts[1]
            .parse::<u16>()
            .map_err(ParseProtocolSemanticVersionError::ParseIntError)?;

        let patch = parts[2]
            .parse::<u32>()
            .map_err(ParseProtocolSemanticVersionError::ParseIntError)?;

        Ok(ProtocolSemanticVersion {
            minor: minor.into(),
            patch: patch.into(),
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ParseProtocolSemanticVersionError {
    #[error("invalid format")]
    InvalidFormat,
    #[error("non zero major version")]
    NonZeroMajorVersion,
    #[error("{0}")]
    ParseIntError(std::num::ParseIntError),
}
