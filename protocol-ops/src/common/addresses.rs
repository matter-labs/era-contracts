/// The zero address, used for unset optional protocol addresses.
pub const ZERO_ADDRESS: &str = "0x0000000000000000000000000000000000000000";

/// ETH pseudo-token address used by chain registration configs.
pub const ETH_ADDRESS: &str = "0x0000000000000000000000000000000000000001";

/// Mainnet WETH address used by the default L1 deployment config.
pub const MAINNET_WETH_ADDRESS: &str = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

/// Sepolia WETH address. Pass via `--token-weth-address` when deploying an
/// ecosystem on Sepolia; the default config carries the mainnet address.
pub const SEPOLIA_WETH_ADDRESS: &str = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";

/// Locally deployed ZK token address used by interop fixtures.
pub const LOCAL_ZK_TOKEN_ADDRESS: &str = "0x8207187d1682B3ebaF2e1bdE471aC9d5B886fD93";

/// Localhost ZK token asset ID derived from [`LOCAL_ZK_TOKEN_ADDRESS`].
pub const LOCAL_ZK_TOKEN_ASSET_ID: &str =
    "0x50c8daa176d24869d010ad74c2d374427601375ca2264e94f73784e299d572d4";

/// Placeholder ZK token asset ID used by gateway vote-preparation input templates.
pub const DEFAULT_ZK_TOKEN_ASSET_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000001";

/// Default CREATE2 salt used by generated script config templates.
pub const ZERO_BYTES32: &str = "0x0000000000000000000000000000000000000000000000000000000000000000";

/// L2 system address of the Bridgehub on the gateway chain.
pub const GATEWAY_L2_BRIDGEHUB: &str = "0x0000000000000000000000000000000000010002";

/// L2 system address of the bootloader.
pub const L2_BOOTLOADER: &str = "0x0000000000000000000000000000000000008001";

/// L2 system address of the L1 messenger.
pub const L2_L1_MESSENGER: &str = "0x0000000000000000000000000000000000008008";

/// Expected first localhost wallet address for the default test mnemonic.
#[cfg(test)]
pub const DEFAULT_TEST_WALLET_ADDRESS: &str = "0xa61464658AfeAf65CccaaFD3a512b69A83B77618";
