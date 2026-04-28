use anyhow::Context;
use ethers::utils::hex;

pub(crate) fn decode_required_hex(field: &str, value: &str) -> anyhow::Result<Vec<u8>> {
    let trimmed = value.trim();
    let hex_value = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);

    anyhow::ensure!(!hex_value.is_empty(), "{field} must not be empty");
    anyhow::ensure!(
        hex_value.len() % 2 == 0,
        "{field} must contain an even number of hex characters"
    );

    hex::decode(hex_value).with_context(|| format!("{field} is not valid hex"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_or_malformed_hex_fields() {
        assert!(decode_required_hex("field", "0x").is_err());
        assert!(decode_required_hex("field", "0x123").is_err());
        assert!(decode_required_hex("field", "0xzz").is_err());
    }
}
