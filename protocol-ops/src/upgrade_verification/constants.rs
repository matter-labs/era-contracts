use alloy::primitives::{address, b256, Address, B256};

/// EIP-1967 admin slot: `keccak256("eip1967.proxy.admin") - 1`. Read with `eth_getStorageAt`,
/// because a transparent proxy answers `admin()` only to its own admin.
pub const EIP1967_PROXY_ADMIN_SLOT: B256 =
    b256!("0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103");

/// EIP-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
pub const EIP1967_IMPLEMENTATION_SLOT: B256 =
    b256!("0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");

/// `AddressAliasHelper.offset`: an L1 contract's `msg.sender` as an L2 sees it is its address plus
/// this, modulo 2^160.
pub const L1_TO_L2_ALIAS_OFFSET: Address = address!("0x1111000000000000000000000000000000001111");

/// The `L2EcosystemContract` members whose release-table row a genesis force-deployments blob
/// repeats (`DeployCTM._buildForceDeploymentsData`), with their slots. The source-sync test below
/// fails the build if the append-only enum moves one.
pub const FORCE_DEPLOYED_L2_ECOSYSTEM_SLOTS: [(&str, usize); 9] = [
    ("L2Bridgehub", 0),
    ("L2AssetRouter", 1),
    ("L2NativeTokenVault", 2),
    ("L2MessageRoot", 3),
    ("BaseTokenHolder", 5),
    ("L2ChainAssetHandler", 6),
    ("InteropCenter", 7),
    ("L2InteropHandler", 9),
    ("L2AssetTracker", 10),
];

/// `L2InventoryLib.fixedAddress`: every `L2EcosystemContract` member that has a fixed L2 address,
/// with its slot. The source-sync test below holds it against the library and the enum.
pub const L2_ECOSYSTEM_FIXED_ADDRESSES: [(&str, usize, Address); 21] = [
    ("L2Bridgehub", 0, L2_BRIDGEHUB_ADDR),
    ("L2AssetRouter", 1, L2_ASSET_ROUTER_ADDR),
    ("L2NativeTokenVault", 2, L2_NATIVE_TOKEN_VAULT_ADDR),
    ("L2MessageRoot", 3, L2_MESSAGE_ROOT_ADDR),
    ("UpgradeableBeaconDeployer", 4, L2_NTV_BEACON_DEPLOYER_ADDR),
    ("BaseTokenHolder", 5, L2_BASE_TOKEN_HOLDER_ADDR),
    ("L2ChainAssetHandler", 6, L2_CHAIN_ASSET_HANDLER_ADDR),
    ("InteropCenter", 7, L2_INTEROP_CENTER_ADDR),
    (
        "InteropAttributeParser",
        8,
        L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    ),
    ("L2InteropHandler", 9, L2_INTEROP_HANDLER_ADDR),
    ("L2AssetTracker", 10, L2_ASSET_TRACKER_ADDR),
    ("L2WrappedBaseToken", 11, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR),
    ("L2MessageVerification", 12, L2_MESSAGE_VERIFICATION_ADDR),
    ("L2InteropRootStorage", 13, L2_INTEROP_ROOT_STORAGE_ADDR),
    (
        "L2InteropCommitmentTree",
        20,
        L2_INTEROP_COMMITMENT_TREE_ADDR,
    ),
    ("AtomicFlowManager", 21, L2_ATOMIC_FLOW_MANAGER_ADDR),
    ("L2BaseToken", 22, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR),
    ("L1Messenger", 23, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
    ("SystemContext", 24, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR),
    (
        "RemovedGWAssetTracker",
        25,
        L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    ),
    ("L2ComplexUpgrader", 26, L2_COMPLEX_UPGRADER_ADDR),
];

/// `CTMContract.ServerNotifier` — the slot of the CTM-domain inventory (`ProxyUpgradeRow[]`
/// indexed by `CTMContract`) holding the ServerNotifier row, mandatory in a bootstrap manifest.
/// The source-sync test below fails the build if the append-only enum moves it.
pub const CTM_CONTRACT_SERVER_NOTIFIER_SLOT: usize = 19;

/// `enum L1EcosystemContract`, in declaration order: the slot names of a core transition's
/// ecosystem inventory. The source-sync test below fails the build if the enum changes.
pub const L1_ECOSYSTEM_CONTRACTS: [&str; 9] = [
    "L1Bridgehub",
    "L1ChainAssetHandler",
    "L1MessageRoot",
    "L1Nullifier",
    "L1AssetRouter",
    "L1NativeTokenVault",
    "L1InteropHandler",
    "CTMDeploymentTracker",
    "ChainRegistrationSender",
];

/// `enum CTMContract`, in declaration order: the slot names of a CTM-domain inventory (an
/// operation's `ctmInfrastructure`, a bootstrap's `ctmProxyUpgrades`). The source-sync test below
/// fails the build if the enum changes.
pub const CTM_CONTRACTS: [&str; 21] = [
    "AdminFacet",
    "MailboxFacet",
    "ExecutorFacet",
    "MigratorFacet",
    "CommitterFacet",
    "DiamondInit",
    "ValidatorTimelock",
    "ChainTypeManager",
    "VerifierPlonk",
    "DualVerifier",
    "TestnetVerifier",
    "GatewayCTMDeployerCTM",
    "GatewayCTMDeployerVerifiers",
    "BlobsL1DAValidatorZKsyncOS",
    "GettersFacet",
    "DefaultUpgrade",
    "L1GenesisUpgrade",
    "BytecodesSupplier",
    "PermissionlessValidator",
    "ServerNotifier",
    "L1InteropFeeManager",
];

/// `enum L2EcosystemContract`, in declaration order: the slot names of a release's L2 bytecode
/// table. The source-sync test below fails the build if the enum changes.
pub const L2_ECOSYSTEM_CONTRACTS: [&str; 27] = [
    "L2Bridgehub",
    "L2AssetRouter",
    "L2NativeTokenVault",
    "L2MessageRoot",
    "UpgradeableBeaconDeployer",
    "BaseTokenHolder",
    "L2ChainAssetHandler",
    "InteropCenter",
    "InteropAttributeParser",
    "L2InteropHandler",
    "L2AssetTracker",
    "L2WrappedBaseToken",
    "L2MessageVerification",
    "L2InteropRootStorage",
    "BeaconProxy",
    "L2DefaultUpgrade",
    "BridgedStandardERC20",
    "DiamondProxy",
    "ProxyAdmin",
    "TransparentUpgradeableProxy",
    "L2InteropCommitmentTree",
    "AtomicFlowManager",
    "L2BaseToken",
    "L1Messenger",
    "SystemContext",
    "RemovedGWAssetTracker",
    "L2ComplexUpgrader",
];

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
/// (`BUILT_IN_CONTRACTS_OFFSET + 0x01`). `L2DefaultUpgrade` is not deployed
/// here but at an address derived from its bytecode info.
pub const L2_VERSION_SPECIFIC_UPGRADER_ADDR: Address = l2_addr(0x01);
pub const L2_BRIDGEHUB_ADDR: Address = l2_addr(0x02);
pub const L2_ASSET_ROUTER_ADDR: Address = l2_addr(0x03);
pub const L2_NATIVE_TOKEN_VAULT_ADDR: Address = l2_addr(0x04);
pub const L2_MESSAGE_ROOT_ADDR: Address = l2_addr(0x05);
/// The removed v31 GWAssetTracker's address: the v33 upgrade swaps its system proxy's
/// implementation for `EmptyContract` (see `getRemovedTrackerNeutralizations`).
pub const L2_REMOVED_GW_ASSET_TRACKER_ADDR: Address = l2_addr(0x10);
pub const SLOAD_CONTRACT_ADDR: Address = l2_addr(0x06);
// v33 no longer force-deploys the WrappedBaseToken, so this address is only referenced by the
// address-consistency test below; keep it as part of the canonical L2 address map.
#[allow(dead_code)]
pub const L2_WRAPPED_BASE_TOKEN_IMPL_ADDR: Address = l2_addr(0x07);
pub const L2_INTEROP_ROOT_STORAGE_ADDR: Address = l2_addr(0x08);
pub const L2_MESSAGE_VERIFICATION_ADDR: Address = l2_addr(0x09);
pub const L2_CHAIN_ASSET_HANDLER_ADDR: Address = l2_addr(0x0a);
pub const L2_NTV_BEACON_DEPLOYER_ADDR: Address = l2_addr(0x0b);
pub const L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR: Address = l2_addr(0x0c);
pub const L2_INTEROP_CENTER_ADDR: Address = l2_addr(0x0d);
pub const L2_INTEROP_HANDLER_ADDR: Address = l2_addr(0x0e);
pub const L2_ASSET_TRACKER_ADDR: Address = l2_addr(0x0f);
pub const L2_INTEROP_ATTRIBUTE_PARSER_ADDR: Address = l2_addr(0x15);
pub const L2_INTEROP_COMMITMENT_TREE_ADDR: Address = l2_addr(0x12);
pub const L2_ATOMIC_FLOW_MANAGER_ADDR: Address = l2_addr(0x14);
pub const L2_BASE_TOKEN_HOLDER_ADDR: Address = l2_addr(0x11);

/// L2 system contract addresses (`SYSTEM_CONTRACTS_OFFSET + <offset>`).
/// Current addresses match `L2ContractAddresses.sol`; this verifier module
/// also retains its version-specific Era address constants.
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
/// Historical Era Keccak precompile address.
pub const KECCAK256_SYSTEM_CONTRACT: Address = literal_addr(0x8010);

/// EVM precompile addresses.
pub const ECRECOVER_SYSTEM_CONTRACT: Address = literal_addr(0x01);
pub const SHA256_SYSTEM_CONTRACT: Address = literal_addr(0x02);
pub const IDENTITY_SYSTEM_CONTRACT: Address = literal_addr(0x04);
pub const MODEXP_SYSTEM_CONTRACT: Address = literal_addr(0x05);
pub const ECADD_SYSTEM_CONTRACT: Address = literal_addr(0x06);
pub const ECMUL_SYSTEM_CONTRACT: Address = literal_addr(0x07);
pub const ECPAIRING_SYSTEM_CONTRACT: Address = literal_addr(0x08);

/// L2 protocol upgrade transaction parameters.
/// ZKsync OS upgrade txs use txType 126 (Era VM's 254 is gone with the Era
/// CTM); gas + pubdata limits are fixed by the upgrade deploy scripts and
/// travel with the artifact.
pub const ZKSYNC_OS_SYSTEM_UPGRADE_TX_TYPE: u64 = 126;
pub const L2_UPGRADE_GAS_LIMIT: u64 = 72_000_000;
pub const L2_UPGRADE_GAS_PER_PUBDATA_BYTE_LIMIT: u64 = 800;

/// AllContractsHashes file-name key consulted by the bytecode verifier.
pub const L2_DEFAULT_UPGRADE_CONTRACT: &str = "l1-contracts/L2DefaultUpgrade";

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

    /// Asserts current contract addresses match their Solidity definitions.
    /// `include_str!` resolves at compile time, so a renamed/moved Solidity
    /// file fails the build rather than silently skipping the check.
    #[test]
    fn matches_solidity_source() {
        const L2_CONTRACT_ADDRESSES: &str = include_str!(
            "../../../l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol"
        );
        let addrs = parse_solidity_addresses(L2_CONTRACT_ADDRESSES);

        // Current constants must appear in the Solidity source with the
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
            ("L2_NTV_BEACON_DEPLOYER_ADDR", L2_NTV_BEACON_DEPLOYER_ADDR),
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
            (
                "L2_DEPLOYER_SYSTEM_CONTRACT_ADDR",
                L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            ),
            ("L2_FORCE_DEPLOYER_ADDR", L2_FORCE_DEPLOYER_ADDR),
            (
                "L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR",
                L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            ),
            (
                "L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR",
                L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            ),
            (
                "L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR",
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            ),
            ("L2_COMPLEX_UPGRADER_ADDR", L2_COMPLEX_UPGRADER_ADDR),
        ] {
            let actual = addrs
                .get(sol_name)
                .copied()
                .unwrap_or_else(|| panic!("{sol_name} not found in Solidity source"));
            assert_eq!(expected, actual, "{sol_name} drift vs Solidity source");
        }
    }

    /// The slot is the member's position in `enum CTMContract`, read from the Solidity source.
    const CONTRACT_IDENTIFIERS: &str = include_str!(
        "../../../l1-contracts/contracts/upgrades/registry/libraries/ContractIdentifiers.sol"
    );

    /// The members of `enum <name>` in ContractIdentifiers.sol, in declaration order. Comments
    /// are dropped before looking for the closing brace: they cite docs as `{path}`.
    fn enum_members(name: &str) -> Vec<&'static str> {
        let body = CONTRACT_IDENTIFIERS
            .split_once(&format!("enum {name} {{"))
            .unwrap_or_else(|| panic!("ContractIdentifiers.sol must declare `enum {name}`"))
            .1;
        let mut members = Vec::new();
        for line in body.lines() {
            let code = line.split("//").next().unwrap_or_default();
            let (code, closed) = code
                .split_once('}')
                .map_or((code, false), |(code, _)| (code, true));
            members.extend(
                code.split(',')
                    .map(str::trim)
                    .filter(|member| !member.is_empty()),
            );
            if closed {
                return members;
            }
        }
        panic!("enum {name} must be closed");
    }

    #[test]
    fn the_server_notifier_slot_is_its_ctm_contract_position() {
        assert_eq!(
            enum_members("CTMContract")
                .iter()
                .position(|m| *m == "ServerNotifier"),
            Some(CTM_CONTRACT_SERVER_NOTIFIER_SLOT),
            "CTMContract.ServerNotifier moved; update CTM_CONTRACT_SERVER_NOTIFIER_SLOT"
        );
    }

    /// The inventory slot names are the Solidity enums, member for member: a slot check that
    /// named the wrong member would hold a row against another contract's proxy.
    #[test]
    fn the_inventory_slot_names_are_the_solidity_enums() {
        assert_eq!(
            enum_members("L1EcosystemContract"),
            L1_ECOSYSTEM_CONTRACTS.to_vec()
        );
        assert_eq!(enum_members("CTMContract"), CTM_CONTRACTS.to_vec());
        assert_eq!(
            enum_members("L2EcosystemContract"),
            L2_ECOSYSTEM_CONTRACTS.to_vec()
        );
    }

    #[test]
    fn the_force_deployed_slots_are_their_l2_ecosystem_contract_positions() {
        let members = enum_members("L2EcosystemContract");
        for (member, slot) in FORCE_DEPLOYED_L2_ECOSYSTEM_SLOTS {
            assert_eq!(
                members.iter().position(|m| *m == member),
                Some(slot),
                "L2EcosystemContract.{member} moved; update FORCE_DEPLOYED_L2_ECOSYSTEM_SLOTS"
            );
        }
    }

    /// Every `if (_member == L2EcosystemContract.<member>) { return <constant>; }` arm of
    /// `L2InventoryLib.fixedAddress` is a row of the table, at the member's enum position and the
    /// constant's address, and the table has no other row.
    #[test]
    fn the_fixed_addresses_are_l2_inventory_libs() {
        const L2_INVENTORY_LIB: &str = include_str!(
            "../../../l1-contracts/contracts/upgrades/registry/libraries/L2InventoryLib.sol"
        );
        const L2_CONTRACT_ADDRESSES: &str = include_str!(
            "../../../l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol"
        );
        let addresses = parse_solidity_addresses(L2_CONTRACT_ADDRESSES);
        let members = enum_members("L2EcosystemContract");
        let arms: Vec<(&str, &str)> = L2_INVENTORY_LIB
            .split("if (_member == L2EcosystemContract.")
            .skip(1)
            .map(|arm| {
                let (member, rest) = arm.split_once(')').expect("the arm's condition closes");
                let constant = rest
                    .split_once("return ")
                    .and_then(|(_, after)| after.split_once(';'))
                    .expect("the arm returns a constant")
                    .0;
                (member, constant)
            })
            .collect();
        assert_eq!(
            arms.len(),
            L2_ECOSYSTEM_FIXED_ADDRESSES.len(),
            "L2InventoryLib.fixedAddress gained or lost a member; update L2_ECOSYSTEM_FIXED_ADDRESSES"
        );
        for (member, constant) in arms {
            let address = addresses
                .get(constant)
                .copied()
                .unwrap_or_else(|| panic!("{constant} not found in L2ContractAddresses.sol"));
            let slot = members
                .iter()
                .position(|m| *m == member)
                .unwrap_or_else(|| panic!("{member} is not an L2EcosystemContract member"));
            assert!(
                L2_ECOSYSTEM_FIXED_ADDRESSES.contains(&(member, slot, address)),
                "L2_ECOSYSTEM_FIXED_ADDRESSES must hold ({member}, {slot}, {address})"
            );
        }
    }

    /// The offset is `AddressAliasHelper`'s.
    #[test]
    fn the_alias_offset_is_the_helpers() {
        const ALIAS_HELPER: &str =
            include_str!("../../../l1-contracts/contracts/vendor/AddressAliasHelper.sol");
        assert!(ALIAS_HELPER.contains(&format!(
            "uint160 private constant offset = uint160({});",
            alloy::hex::encode_prefixed(L1_TO_L2_ALIAS_OFFSET)
        )));
    }

    #[test]
    fn the_eip1967_implementation_slot_is_the_standard_preimage() {
        let slot = alloy::primitives::U256::from_be_bytes(
            alloy::primitives::keccak256(b"eip1967.proxy.implementation").0,
        ) - alloy::primitives::U256::from(1);
        assert_eq!(B256::from(slot), EIP1967_IMPLEMENTATION_SLOT);
    }

    #[test]
    fn the_eip1967_admin_slot_is_the_standard_preimage() {
        let slot = alloy::primitives::U256::from_be_bytes(
            alloy::primitives::keccak256(b"eip1967.proxy.admin").0,
        ) - alloy::primitives::U256::from(1);
        assert_eq!(B256::from(slot), EIP1967_PROXY_ADMIN_SLOT);
    }
}
