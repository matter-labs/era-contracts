use alloy::primitives::{address, Address};

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

/// Builds an L2 system-contract address from a 16-bit offset into the
/// `SYSTEM_CONTRACTS_OFFSET` range (`0x8000..=0xffff`).
const fn system_contract_addr(offset: u16) -> Address {
    let base = 0x8000u32 + offset as u32;
    let mut bytes = [0u8; 20];
    bytes[18] = ((base >> 8) & 0xff) as u8;
    bytes[19] = (base & 0xff) as u8;
    Address::new(bytes)
}

/// Builds an address whose last 4 bytes equal `value`. Use for "bare" Solidity
/// declarations like `address(0x01)` (precompiles) or `address(0x8010)`
/// (`KECCAK256_SYSTEM_CONTRACT` — Solidity hardcodes the literal rather than
/// the `SYSTEM_CONTRACTS_OFFSET + 0x10` offset form).
pub const fn literal_addr(value: u32) -> Address {
    let mut bytes = [0u8; 20];
    bytes[16] = ((value >> 24) & 0xff) as u8;
    bytes[17] = ((value >> 16) & 0xff) as u8;
    bytes[18] = ((value >> 8) & 0xff) as u8;
    bytes[19] = (value & 0xff) as u8;
    Address::new(bytes)
}

/// L2 built-in system contract addresses.
///
/// Mirrors `l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`.
/// These are protocol-level constants: built-in L2 system contracts live at
/// `BUILT_IN_CONTRACTS_OFFSET (0x10000) + <index>` and are part of the
/// protocol spec, not deployed per-chain.
///
/// The parser-based test below reads the Solidity source directly and will
/// fail loudly if a name disappears or its offset drifts.
pub const L2_CREATE2_FACTORY_ADDR: Address = l2_addr(0x00);
/// EVM deterministic CREATE2 factory used by ZKsync OS L1->L2 priority
/// deployment transactions.
pub const ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR: Address =
    address!("0x4e59b44847b379578588920ca78fbf26c0b4956c");
/// Alias of `L2_GENESIS_UPGRADE_ADDR` in Solidity — same on-chain address
/// (`BUILT_IN_CONTRACTS_OFFSET + 0x01`), exposed under the version-specific
/// name because v31 force-deploys `L2V32Upgrade` there.
pub const L2_VERSION_SPECIFIC_UPGRADER_ADDR: Address = l2_addr(0x01);
pub const L2_BRIDGEHUB_ADDR: Address = l2_addr(0x02);
pub const L2_ASSET_ROUTER_ADDR: Address = l2_addr(0x03);
pub const L2_NATIVE_TOKEN_VAULT_ADDR: Address = l2_addr(0x04);
pub const L2_MESSAGE_ROOT_ADDR: Address = l2_addr(0x05);
/// The removed v31 GWAssetTracker's address: the v32 upgrade swaps its system proxy's
/// implementation for `EmptyContract` (see `getRemovedTrackerNeutralizations`).
pub const L2_REMOVED_GW_ASSET_TRACKER_ADDR: Address = l2_addr(0x10);
pub const SLOAD_CONTRACT_ADDR: Address = l2_addr(0x06);
// v31 no longer force-deploys the WrappedBaseToken, so this address is only referenced by the
// address-consistency test below; keep it as part of the canonical L2 address map.
#[allow(dead_code)]
pub const L2_WRAPPED_BASE_TOKEN_IMPL_ADDR: Address = l2_addr(0x07);
pub const L2_INTEROP_ROOT_STORAGE_ADDR: Address = l2_addr(0x08);
pub const L2_MESSAGE_VERIFICATION_ADDR: Address = l2_addr(0x09);
pub const L2_CHAIN_ASSET_HANDLER_ADDR: Address = l2_addr(0x0a);
pub const L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR: Address = l2_addr(0x0c);
pub const L2_INTEROP_CENTER_ADDR: Address = l2_addr(0x0d);
pub const L2_INTEROP_HANDLER_ADDR: Address = l2_addr(0x0e);
pub const L2_ASSET_TRACKER_ADDR: Address = l2_addr(0x0f);
pub const L2_INTEROP_ATTRIBUTE_PARSER_ADDR: Address = l2_addr(0x15);
pub const L2_INTEROP_COMMITMENT_TREE_ADDR: Address = l2_addr(0x12);
pub const L2_ATOMIC_FLOW_MANAGER_ADDR: Address = l2_addr(0x14);
pub const L2_BASE_TOKEN_HOLDER_ADDR: Address = l2_addr(0x11);

/// L2 system contract addresses (`SYSTEM_CONTRACTS_OFFSET + <offset>`).
/// Sourced from `L2ContractAddresses.sol` where available; the rest live in
/// `system-contracts/contracts/Constants.sol`.
pub const L2_BOOTLOADER_ADDRESS: Address = system_contract_addr(0x01);
pub const L2_ACCOUNT_CODE_STORAGE_ADDR: Address = system_contract_addr(0x02);
pub const L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR: Address = system_contract_addr(0x04);
pub const L2_DEPLOYER_SYSTEM_CONTRACT_ADDR: Address = system_contract_addr(0x06);
pub const L2_FORCE_DEPLOYER_ADDR: Address = system_contract_addr(0x07);
pub const L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR: Address = system_contract_addr(0x08);
pub const MSG_VALUE_SYSTEM_CONTRACT: Address = system_contract_addr(0x09);
pub const L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR: Address = system_contract_addr(0x0a);
pub const L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR: Address = system_contract_addr(0x0b);
pub const EVENT_WRITER_CONTRACT: Address = system_contract_addr(0x0d);
pub const L2_COMPRESSOR_ADDR: Address = system_contract_addr(0x0e);
pub const L2_COMPLEX_UPGRADER_ADDR: Address = system_contract_addr(0x0f);
pub const L2_PUBDATA_CHUNK_PUBLISHER_ADDR: Address = system_contract_addr(0x11);
pub const CODE_ORACLE_SYSTEM_CONTRACT: Address = system_contract_addr(0x12);
pub const EVM_GAS_MANAGER: Address = system_contract_addr(0x13);
pub const EVM_PREDEPLOYS_MANAGER: Address = system_contract_addr(0x14);
/// Solidity hardcodes this as `address(0x8010)` rather than the offset form;
/// see the comment in `system-contracts/Constants.sol`. The value is still
/// `SYSTEM_CONTRACTS_OFFSET + 0x10`.
pub const KECCAK256_SYSTEM_CONTRACT: Address = literal_addr(0x8010);

/// EVM precompile addresses. Sourced from `system-contracts/Constants.sol`
/// where they're declared as `address(0xNN)` literals (no offset).
pub const ECRECOVER_SYSTEM_CONTRACT: Address = literal_addr(0x01);
pub const SHA256_SYSTEM_CONTRACT: Address = literal_addr(0x02);
pub const IDENTITY_SYSTEM_CONTRACT: Address = literal_addr(0x04);
pub const MODEXP_SYSTEM_CONTRACT: Address = literal_addr(0x05);
pub const ECADD_SYSTEM_CONTRACT: Address = literal_addr(0x06);
pub const ECMUL_SYSTEM_CONTRACT: Address = literal_addr(0x07);
pub const ECPAIRING_SYSTEM_CONTRACT: Address = literal_addr(0x08);

/// v31 L2 protocol upgrade transaction parameters.
/// `txType` differs between Era VM (254) and ZKsync OS (126); gas + pubdata
/// limits are fixed by v31 deploy scripts and travel with the artifact.
pub const ERA_SYSTEM_UPGRADE_TX_TYPE: u64 = 254;
pub const ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE: u64 = 126;
pub const L2_UPGRADE_GAS_LIMIT: u64 = 72_000_000;
pub const L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT: u64 = 800;

/// AllContractsHashes file-name keys consulted by the bytecode verifier.
pub const L2_V32_UPGRADE_CONTRACT: &str = "l1-contracts/L2V32Upgrade";
pub const BOOTLOADER_CONTRACT: &str = "Bootloader";
pub const DEFAULT_ACCOUNT_CONTRACT: &str = "system-contracts/DefaultAccount";
pub const EVM_EMULATOR_CONTRACT: &str = "EvmEmulator";

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Parses Solidity address declarations from `source` and returns a
    /// `name -> Address` map. Handles three declaration shapes:
    /// - `address constant <NAME> = address(BUILT_IN_CONTRACTS_OFFSET + 0x<hex>);`
    /// - `address constant <NAME> = address(SYSTEM_CONTRACTS_OFFSET + 0x<hex>);`
    /// - `address constant <NAME> = address(0x<hex>);` (precompiles, KECCAK)
    /// - `address constant <NAME> = 0x<40-hex-chars>;` (well-known deployed addresses)
    ///
    /// Also matches the `address payable constant ... = payable(address(...))`
    /// wrapper used for `L2_INTEROP_HANDLER_ADDR` / `BOOTLOADER_FORMAL_ADDRESS`.
    /// `USER_CONTRACTS_OFFSET` (an alias of `BUILT_IN_CONTRACTS_OFFSET` in
    /// `Constants.sol`) is intentionally ignored — those entries duplicate
    /// the BUILT_IN ones in `L2ContractAddresses.sol`.
    fn parse_solidity_addresses(source: &str) -> HashMap<String, Address> {
        enum Pattern {
            BuiltIn(usize),
            System(usize),
            Literal(usize),
            FullLiteral(usize),
        }
        let mut out = HashMap::new();
        for line in source.lines() {
            if line.trim_start().starts_with("//") {
                continue;
            }
            let pattern = if let Some(p) = line.find("address(BUILT_IN_CONTRACTS_OFFSET + 0x") {
                Pattern::BuiltIn(p + "address(BUILT_IN_CONTRACTS_OFFSET + 0x".len())
            } else if let Some(p) = line.find("address(SYSTEM_CONTRACTS_OFFSET + 0x") {
                Pattern::System(p + "address(SYSTEM_CONTRACTS_OFFSET + 0x".len())
            } else if let Some(p) = line.find("address(0x") {
                Pattern::Literal(p + "address(0x".len())
            } else if line.contains("address") && line.contains("= 0x") {
                let p = line.find("= 0x").expect("checked above");
                Pattern::FullLiteral(p + "= 0x".len())
            } else {
                continue;
            };
            let Some(constant_pos) = line.find("constant ") else {
                continue;
            };

            let after_constant = &line[constant_pos + "constant ".len()..];
            let name_len = after_constant
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .unwrap_or(after_constant.len());
            let name = after_constant[..name_len].to_string();

            if let Pattern::FullLiteral(start) = pattern {
                let after = &line[start..];
                let hex_len = after
                    .find(|c: char| !c.is_ascii_hexdigit())
                    .unwrap_or(after.len());
                let raw = &after[..hex_len];
                let decoded = alloy::hex::decode(raw)
                    .unwrap_or_else(|err| panic!("bad full address hex for {name}: {err}"));
                let addr = Address::try_from(decoded.as_slice())
                    .unwrap_or_else(|err| panic!("bad full address length for {name}: {err}"));
                out.insert(name, addr);
                continue;
            }

            let (start, build): (usize, fn(u32) -> Address) = match pattern {
                Pattern::BuiltIn(s) => (s, |v| l2_addr(v as u16)),
                Pattern::System(s) => (s, |v| system_contract_addr(v as u16)),
                Pattern::Literal(s) => (s, literal_addr),
                Pattern::FullLiteral(_) => unreachable!(),
            };
            let after = &line[start..];
            let hex_len = after
                .find(|c: char| !c.is_ascii_hexdigit())
                .unwrap_or(after.len());
            let value = u32::from_str_radix(&after[..hex_len], 16)
                .unwrap_or_else(|err| panic!("bad hex for {name}: {err}"));

            out.insert(name, build(value));
        }
        out
    }

    /// Asserts every Rust address constant matches its Solidity definition.
    /// `include_str!` resolves at compile time, so a renamed/moved Solidity
    /// file fails the build rather than silently skipping the check.
    #[test]
    fn matches_solidity_source() {
        const L2_CONTRACT_ADDRESSES: &str = include_str!(
            "../../../l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol"
        );
        const SYSTEM_CONSTANTS: &str =
            include_str!("../../../system-contracts/contracts/Constants.sol");

        let mut addrs = parse_solidity_addresses(L2_CONTRACT_ADDRESSES);
        // Later inserts overwrite — fine because any duplicate names across
        // the two files (e.g. `MSG_VALUE_SYSTEM_CONTRACT`) resolve to the
        // same address.
        addrs.extend(parse_solidity_addresses(SYSTEM_CONSTANTS));

        // Every Rust constant must appear in the Solidity source with the
        // same on-chain address. For aliases the Solidity-side name differs
        // from the Rust-side name (e.g. `L2_VERSION_SPECIFIC_UPGRADER_ADDR`
        // is `= L2_GENESIS_UPGRADE_ADDR`); look up by the Solidity name.
        for (sol_name, expected) in [
            // BUILT_IN_CONTRACTS_OFFSET range
            ("L2_CREATE2_FACTORY_ADDR", L2_CREATE2_FACTORY_ADDR),
            (
                "ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR",
                ZKSYNC_OS_DETERMINISTIC_CREATE2_ADDR,
            ),
            ("L2_GENESIS_UPGRADE_ADDR", L2_VERSION_SPECIFIC_UPGRADER_ADDR),
            ("L2_BRIDGEHUB_ADDR", L2_BRIDGEHUB_ADDR),
            ("L2_ASSET_ROUTER_ADDR", L2_ASSET_ROUTER_ADDR),
            ("L2_NATIVE_TOKEN_VAULT_ADDR", L2_NATIVE_TOKEN_VAULT_ADDR),
            ("L2_MESSAGE_ROOT_ADDR", L2_MESSAGE_ROOT_ADDR),
            ("SLOAD_CONTRACT_ADDR", SLOAD_CONTRACT_ADDR),
            (
                "L2_WRAPPED_BASE_TOKEN_IMPL_ADDR",
                L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            ),
            ("L2_INTEROP_ROOT_STORAGE_ADDR", L2_INTEROP_ROOT_STORAGE_ADDR),
            ("L2_MESSAGE_VERIFICATION_ADDR", L2_MESSAGE_VERIFICATION_ADDR),
            ("L2_CHAIN_ASSET_HANDLER_ADDR", L2_CHAIN_ASSET_HANDLER_ADDR),
            (
                "L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR",
                L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
            ),
            ("L2_INTEROP_CENTER_ADDR", L2_INTEROP_CENTER_ADDR),
            ("L2_INTEROP_HANDLER_ADDR", L2_INTEROP_HANDLER_ADDR),
            ("L2_ASSET_TRACKER_ADDR", L2_ASSET_TRACKER_ADDR),
            ("L2_BASE_TOKEN_HOLDER_ADDR", L2_BASE_TOKEN_HOLDER_ADDR),
            (
                "L2_REMOVED_GW_ASSET_TRACKER_ADDR",
                L2_REMOVED_GW_ASSET_TRACKER_ADDR,
            ),
            // SYSTEM_CONTRACTS_OFFSET range
            ("L2_BOOTLOADER_ADDRESS", L2_BOOTLOADER_ADDRESS),
            ("L2_ACCOUNT_CODE_STORAGE_ADDR", L2_ACCOUNT_CODE_STORAGE_ADDR),
            (
                "L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR",
                L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR,
            ),
            (
                "L2_DEPLOYER_SYSTEM_CONTRACT_ADDR",
                L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            ),
            ("L2_FORCE_DEPLOYER_ADDR", L2_FORCE_DEPLOYER_ADDR),
            (
                "L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR",
                L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            ),
            ("MSG_VALUE_SYSTEM_CONTRACT", MSG_VALUE_SYSTEM_CONTRACT),
            (
                "L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR",
                L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            ),
            (
                "L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR",
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            ),
            ("EVENT_WRITER_CONTRACT", EVENT_WRITER_CONTRACT),
            ("L2_COMPRESSOR_ADDR", L2_COMPRESSOR_ADDR),
            ("L2_COMPLEX_UPGRADER_ADDR", L2_COMPLEX_UPGRADER_ADDR),
            (
                "L2_PUBDATA_CHUNK_PUBLISHER_ADDR",
                L2_PUBDATA_CHUNK_PUBLISHER_ADDR,
            ),
            ("CODE_ORACLE_SYSTEM_CONTRACT", CODE_ORACLE_SYSTEM_CONTRACT),
            ("EVM_GAS_MANAGER", EVM_GAS_MANAGER),
            ("EVM_PREDEPLOYS_MANAGER", EVM_PREDEPLOYS_MANAGER),
            // Hardcoded literal (`address(0x8010)`)
            ("KECCAK256_SYSTEM_CONTRACT", KECCAK256_SYSTEM_CONTRACT),
            // EVM precompiles (literal `address(0xNN)`)
            ("ECRECOVER_SYSTEM_CONTRACT", ECRECOVER_SYSTEM_CONTRACT),
            ("SHA256_SYSTEM_CONTRACT", SHA256_SYSTEM_CONTRACT),
            ("IDENTITY_SYSTEM_CONTRACT", IDENTITY_SYSTEM_CONTRACT),
            ("MODEXP_SYSTEM_CONTRACT", MODEXP_SYSTEM_CONTRACT),
            ("ECADD_SYSTEM_CONTRACT", ECADD_SYSTEM_CONTRACT),
            ("ECMUL_SYSTEM_CONTRACT", ECMUL_SYSTEM_CONTRACT),
            ("ECPAIRING_SYSTEM_CONTRACT", ECPAIRING_SYSTEM_CONTRACT),
        ] {
            let actual = addrs
                .get(sol_name)
                .copied()
                .unwrap_or_else(|| panic!("{sol_name} not found in Solidity source"));
            assert_eq!(expected, actual, "{sol_name} drift vs Solidity source");
        }
    }
}
