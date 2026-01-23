use alloy::primitives::{Address, FixedBytes, B256};

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

/// The address of the base token holder contract that holds chain's base token reserves.
/// Located at USER_CONTRACTS_OFFSET + 0x11 = 0x10011
pub const BASE_TOKEN_HOLDER_ADDR: Address = Address(FixedBytes::<20>(hex_literal::hex!(
    "0000000000000000000000000000000000010011"
)));

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

pub const INITIAL_CONTRACTS: [(Address, &str); 19] = [
    (L2_COMPLEX_UPGRADER_ADDR, "SystemContractProxy"),
    (L2_GENESIS_UPGRADE, "L2GenesisUpgrade"),
    (L2_WRAPPED_BASE_TOKEN, "L2WrappedBaseToken"),
    (SYSTEM_CONTRACT_PROXY_ADMIN, "SystemContractProxyAdmin"),
    (L2_COMPLEX_UPGRADER_IMPL_ADDR, "L2ComplexUpgrader"),
    (L2_MESSAGE_ROOT_ADDR, "L2MessageRoot"),
    (L2_BRIDGEHUB_ADDR, "L2BridgeHub"),
    (L2_ASSET_ROUTER_ADDR, "L2AssetRouter"),
    (L2_NATIVE_TOKEN_VAULT_ADDR, "L2NativeTokenVaultZKOS"),
    (L2_NTV_BEACON_DEPLOYER_ADDR, "UpgradeableBeaconDeployer"),
    (L2_CHAIN_ASSET_HANDLER_ADDR, "L2ChainAssetHandler"),
    (L2_ASSET_TRACKER_ADDR, "L2AssetTracker"),
    (GW_ASSET_TRACKER_ADDR, "GWAssetTracker"),
    (L2_INTEROP_CENTER_ADDR, "InteropCenter"),
    (L2_INTEROP_HANDLER_ADDR, "InteropHandler"),
    (BASE_TOKEN_HOLDER_ADDR, "BaseTokenHolder"),
    // System contracts (0x8000 range)
    (L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, "ZKOSContractDeployer"),
    (L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, "L1Messenger"),
    (L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, "L2BaseToken"),
];
