use alloy::primitives::{Address, FixedBytes, B256};

/// Represents the source of a contract's bytecode.
#[derive(Clone, Copy)]
pub enum ContractSource {
    /// Load bytecode from a compiled contract artifact by name.
    Name(&'static str),
    /// Use bytecode directly.
    Bytecode(&'static [u8]),
}

pub const L2_COMPLEX_UPGRADER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000000800f"
)));
pub const L2_GENESIS_UPGRADE: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010001"
)));
pub const L2_WRAPPED_BASE_TOKEN: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010007"
)));
pub const SYSTEM_CONTRACT_PROXY_ADMIN: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000c"
)));

pub const L2_MESSAGE_ROOT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010005"
)));

pub const L2_BRIDGEHUB_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010002"
)));

pub const L2_ASSET_ROUTER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010003"
)));

pub const L2_NATIVE_TOKEN_VAULT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010004"
)));

pub const L2_NTV_BEACON_DEPLOYER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000b"
)));

pub const L2_CHAIN_ASSET_HANDLER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000a"
)));

pub const L2_INTEROP_CENTER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000d"
)));

pub const L2_INTEROP_HANDLER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000e"
)));

pub const L2_ASSET_TRACKER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000001000f"
)));

pub const GW_ASSET_TRACKER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010010"
)));

pub const L2_INTEROP_ROOT_STORAGE: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010008"
)));
pub const L2_MESSAGE_VERIFICATION: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010009"
)));

// Deterministic Create2 factory
// https://github.com/Arachnid/deterministic-deployment-proxy
pub const DETERMINISTIC_CREATE2_ADDRESS: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "4e59b44847b379578588920cA78FbF26c0B4956C"
)));
pub const CREATE2_FACTORY_BYTECODE: &[u8] = &hex_literal::hex!(
    "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
);

// System contracts
pub const L2_DEPLOYER_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000008006"
)));

pub const L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000008008"
)));

pub const L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "000000000000000000000000000000000000800a"
)));

// keccak256("L2_COMPLEX_UPGRADER_IMPL_ADDR") - 1.
// We need it predeployed to make the genesis upgrade work at all.
pub const L2_COMPLEX_UPGRADER_IMPL_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "d704e29df32c189b8613f79fcc043b2dc01d5f53"
)));
pub const SYSTEM_PROXY_ADMIN_OWNER_SLOT: B256 = B256::ZERO;

pub const EIP1967_IMPLEMENTATION_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
));
pub const EIP1967_ADMIN_SLOT: B256 = FixedBytes::<32>(hex_literal::hex!(
    "b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
));

pub const INITIAL_CONTRACTS: [(Address, ContractSource); 21] = [
    (L2_COMPLEX_UPGRADER_ADDR, ContractSource::Name("SystemContractProxy")),
    (L2_GENESIS_UPGRADE, ContractSource::Name("L2GenesisUpgrade")),
    (L2_WRAPPED_BASE_TOKEN, ContractSource::Name("L2WrappedBaseToken")),
    (SYSTEM_CONTRACT_PROXY_ADMIN, ContractSource::Name("SystemContractProxyAdmin")),
    (L2_COMPLEX_UPGRADER_IMPL_ADDR, ContractSource::Name("L2ComplexUpgrader")),
    (L2_MESSAGE_ROOT_ADDR, ContractSource::Name("L2MessageRoot")),
    (L2_BRIDGEHUB_ADDR, ContractSource::Name("L2BridgeHub")),
    (L2_ASSET_ROUTER_ADDR, ContractSource::Name("L2AssetRouter")),
    (L2_NATIVE_TOKEN_VAULT_ADDR, ContractSource::Name("L2NativeTokenVaultZKOS")),
    (L2_NTV_BEACON_DEPLOYER_ADDR, ContractSource::Name("UpgradeableBeaconDeployer")),
    (L2_CHAIN_ASSET_HANDLER_ADDR, ContractSource::Name("L2ChainAssetHandler")),
    (L2_ASSET_TRACKER_ADDR, ContractSource::Name("L2AssetTracker")),
    (GW_ASSET_TRACKER_ADDR, ContractSource::Name("GWAssetTracker")),
    (L2_INTEROP_CENTER_ADDR, ContractSource::Name("InteropCenter")),
    (L2_INTEROP_HANDLER_ADDR, ContractSource::Name("InteropHandler")),
    (L2_INTEROP_ROOT_STORAGE, ContractSource::Name("L2InteropRootStorage")),
    (L2_MESSAGE_VERIFICATION, ContractSource::Name("L2MessageVerification")),
    // System contracts (0x8000 range)
    (L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, ContractSource::Name("ZKOSContractDeployer")),
    (L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, ContractSource::Name("L1Messenger")),
    (L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, ContractSource::Name("L2BaseToken")),
    // Deterministic Create2 factory
    (DETERMINISTIC_CREATE2_ADDRESS, ContractSource::Bytecode(CREATE2_FACTORY_BYTECODE)),
];
