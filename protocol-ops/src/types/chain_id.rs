use std::{fmt, str::FromStr};
use ethers::types::U64;
use serde::{de, Deserialize, Deserializer, Serialize};


#[derive(Copy, Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct L1ChainId(u64);

#[derive(Copy, Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct L2ChainId(u64);

impl<'de> Deserialize<'de> for L2ChainId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        if deserializer.is_human_readable() {
            let value: serde_json::Value = Deserialize::deserialize(deserializer)?;
            match &value {
                serde_json::Value::Number(number) => Self::new(number.as_u64().ok_or(
                    de::Error::custom(format!("Failed to parse: {}, Expected u64", number)),
                )?)
                .map_err(de::Error::custom),
                serde_json::Value::String(string) => string.parse().map_err(de::Error::custom),
                _ => Err(de::Error::custom(format!(
                    "Failed to parse: {}, Expected number or string",
                    value
                ))),
            }
        } else {
            u64::deserialize(deserializer).map(L2ChainId)
        }
    }
}

impl fmt::Display for L2ChainId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl L2ChainId {
    /// The maximum value of the L2 chain ID.
    // `2^53 - 1` is a max safe integer in JS. In Ethereum JS libraries chain ID should be the safe integer.
    // Next arithmetic operation: subtract 36 and divide by 2 comes from `v` calculation:
    // `v = 2*chainId + 36`, that should be save integer as well.
    const MAX: u64 = ((1 << 53) - 1 - 36) / 2;

    pub fn new(number: u64) -> Result<Self, String> {
        if number > L2ChainId::max().0 {
            return Err(format!(
                "Cannot convert given value {} into L2ChainId. It's greater than MAX: {}",
                number,
                L2ChainId::max().0
            ));
        }
        Ok(L2ChainId(number))
    }

    pub fn max() -> Self {
        Self(Self::MAX)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }

    pub fn inner(&self) -> u64 {
        self.0
    }

    /// Returns the zero L2ChainId. This is a temporarily measure to avoid breaking changes.
    /// Will be removed after prover cluster is integrated on all environments.
    pub fn zero() -> Self {
        Self(0)
    }
}

impl FromStr for L2ChainId {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Parse the string as a U64
        // try to parse as decimal first
        let number = match U64::from_dec_str(s) {
            Ok(u) => u,
            Err(_) => {
                // try to parse as hex
                s.parse::<U64>()
                    .map_err(|err| format!("Failed to parse L2ChainId: Err {err}"))?
            }
        };
        L2ChainId::new(number.as_u64())
    }
}

impl Default for L2ChainId {
    fn default() -> Self {
        Self(270)
    }
}

impl TryFrom<u64> for L2ChainId {
    type Error = String;

    fn try_from(val: u64) -> Result<Self, Self::Error> {
        Self::new(val)
    }
}

impl From<u32> for L2ChainId {
    fn from(value: u32) -> Self {
        // Max value is guaranteed bigger than u32
        Self(u64::from(value))
    }
}
