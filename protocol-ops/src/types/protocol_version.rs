use std::{fmt, str::FromStr};
use serde_with::{DeserializeFromStr, SerializeDisplay};

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
