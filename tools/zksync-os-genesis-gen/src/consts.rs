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
    "0000000000000000000000000000000000010010"
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

pub const INITIAL_CONTRACTS: [(Address, &str); 5] = [
    (L2_COMPLEX_UPGRADER_ADDR, "SystemContractProxy"),
    (L2_GENESIS_UPGRADE, "L2GenesisUpgrade"),
    (L2_WRAPPED_BASE_TOKEN, "L2WrappedBaseToken"),
    (SYSTEM_CONTRACT_PROXY_ADMIN, "SystemContractProxyAdmin"),
    (L2_COMPLEX_UPGRADER_IMPL_ADDR, "L2ComplexUpgrader"),
];
