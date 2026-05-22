use alloy::primitives::Address;

pub const EIP1967_PROXY_ADMIN_SLOT: &str =
    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

/// Builds an L2 built-in address from a 16-bit offset into the
/// `BUILT_IN_CONTRACTS_OFFSET` range (`0x10000..=0x1ffff`).
const fn l2_addr(offset: u16) -> Address {
    let mut bytes = [0u8; 20];
    bytes[17] = 0x01;
    bytes[18] = (offset >> 8) as u8;
    bytes[19] = (offset & 0xff) as u8;
    Address::new(bytes)
}

/// L2 built-in system contract addresses.
///
/// Mirrors `l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`.
/// These are protocol-level constants: built-in L2 system contracts live at
/// `BUILT_IN_CONTRACTS_OFFSET (0x10000) + <index>` and are part of the
/// protocol spec, not deployed per-chain.
///
/// Add only the constants the upgrade-verification crate actually consumes —
/// the parser-based test below reads the Solidity source directly and will
/// fail loudly if a name disappears or its offset drifts.
pub const L2_BRIDGEHUB_ADDR: Address = l2_addr(0x02);
pub const L2_INTEROP_CENTER_ADDR: Address = l2_addr(0x0d);

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Parses `L2ContractAddresses.sol` and asserts every constant we expose
    /// here matches its Solidity definition. `include_str!` resolves at
    /// compile time, so a renamed/moved Solidity file fails the build rather
    /// than silently skipping the check.
    #[test]
    fn matches_solidity_source() {
        const SOL: &str = include_str!(
            "../../../l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol"
        );

        // Capture `<NAME> = ...address(BUILT_IN_CONTRACTS_OFFSET + 0x<hex>)...`
        // lines, e.g.
        //   address constant L2_BRIDGEHUB_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x02);
        //   address payable constant L2_INTEROP_HANDLER_ADDR =
        //       payable(address(BUILT_IN_CONTRACTS_OFFSET + 0x0e));
        let mut offsets: HashMap<&str, u16> = HashMap::new();
        for line in SOL.lines() {
            let Some(offset_pos) = line.find("address(BUILT_IN_CONTRACTS_OFFSET + 0x") else {
                continue;
            };
            let Some(constant_pos) = line.find("constant ") else {
                continue;
            };

            let after_constant = &line[constant_pos + "constant ".len()..];
            let name_len = after_constant
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .unwrap_or(after_constant.len());
            let name = &after_constant[..name_len];

            let after_prefix = &line[offset_pos + "address(BUILT_IN_CONTRACTS_OFFSET + 0x".len()..];
            let hex_len = after_prefix
                .find(|c: char| !c.is_ascii_hexdigit())
                .unwrap_or(after_prefix.len());
            let offset = u16::from_str_radix(&after_prefix[..hex_len], 16)
                .unwrap_or_else(|err| panic!("bad hex offset for {name}: {err}"));

            offsets.insert(name, offset);
        }

        // Every Rust constant must appear in the Solidity source with the
        // same offset.
        for (name, expected) in [
            ("L2_BRIDGEHUB_ADDR", L2_BRIDGEHUB_ADDR),
            ("L2_INTEROP_CENTER_ADDR", L2_INTEROP_CENTER_ADDR),
        ] {
            let offset = offsets
                .get(name)
                .copied()
                .unwrap_or_else(|| panic!("{name} not found in L2ContractAddresses.sol"));
            assert_eq!(expected, l2_addr(offset), "{name} drift vs Solidity source");
        }
    }
}
