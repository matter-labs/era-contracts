// Must match the actual Anvil L1 chain ID (31337 = 0x7a69)
export const L1_CHAIN_ID = 31337;

export const ETH_TOKEN_ADDRESS = "0x0000000000000000000000000000000000000001";
export const LEGACY_SHARED_BRIDGE_PLACEHOLDER = "0x0000000000000000000000000000000000000002";

export const SYSTEM_CONTEXT_ADDR = "0x000000000000000000000000000000000000800b";
export const L2_TO_L1_MESSENGER_ADDR = "0x0000000000000000000000000000000000008008";
export const L2_BASE_TOKEN_ADDR = "0x000000000000000000000000000000000000800a";
export const CONTRACT_DEPLOYER_ADDR = "0x0000000000000000000000000000000000008006";
export const L2_FORCE_DEPLOYER_ADDR = "0x0000000000000000000000000000000000008007";
export const L2_COMPLEX_UPGRADER_ADDR = "0x000000000000000000000000000000000000800f";
export const L2_GENESIS_UPGRADE_ADDR = "0x0000000000000000000000000000000000010001";

export const L2_BRIDGEHUB_ADDR = "0x0000000000000000000000000000000000010002";
export const L2_ASSET_ROUTER_ADDR = "0x0000000000000000000000000000000000010003";
export const L2_NATIVE_TOKEN_VAULT_ADDR = "0x0000000000000000000000000000000000010004";
export const L2_MESSAGE_ROOT_ADDR = "0x0000000000000000000000000000000000010005";
export const L2_WRAPPED_BASE_TOKEN_IMPL_ADDR = "0x0000000000000000000000000000000000010007";
export const L2_MESSAGE_VERIFICATION_ADDR = "0x0000000000000000000000000000000000010009";
export const L2_CHAIN_ASSET_HANDLER_ADDR = "0x000000000000000000000000000000000001000a";
export const L2_NTV_BEACON_DEPLOYER_ADDR = "0x000000000000000000000000000000000001000b";
export const L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR = "0x000000000000000000000000000000000001000c";
export const INTEROP_CENTER_ADDR = "0x000000000000000000000000000000000001000d";
export const L2_INTEROP_HANDLER_ADDR = "0x000000000000000000000000000000000001000e";
export const L2_ASSET_TRACKER_ADDR = "0x000000000000000000000000000000000001000f";
export const GW_ASSET_TRACKER_ADDR = "0x0000000000000000000000000000000000010010";
export const L2_BASE_TOKEN_HOLDER_ADDR = "0x0000000000000000000000000000000000010011";

// ZK-VM system hook address: SYSTEM_HOOKS_OFFSET (0x7000) + 0x100
export const MINT_BASE_TOKEN_HOOK_ADDR = "0x0000000000000000000000000000000000007100";

// From Config.sol: 2^127 - 1 (in hex, used to pre-fund L2BaseToken before genesis initL2)
export const INITIAL_BASE_TOKEN_HOLDER_BALANCE = "0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";

export const ANVIL_DEFAULT_ACCOUNT_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
// Default Anvil account #0 private key
export const ANVIL_DEFAULT_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// 100 ETH in hex — used to fund impersonated accounts
export const ANVIL_FUND_BALANCE = "0x56BC75E2D63100000";

export const SERVICE_TX_SENDER_ADDR = "0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF";

export const INTEROP_BUNDLE_TUPLE_TYPE =
  "tuple(bytes1,uint256,uint256,bytes32,bytes32,tuple(bytes1,bool,address,address,uint256,bytes)[],tuple(bytes,bytes,bool))";
export const INTEROP_BUNDLE_SENT_TOPIC = "0x593b2515b718ee761cd2a586d8613d22833a452122cfb7692ebabd538d57d3ff";

// AddressAliasHelper offset: uint160(0x1111000000000000000000000000000000001111)
export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";

export const ZK_CHAIN_SPECIFIC_FORCE_DEPLOYMENTS_DATA_TUPLE_TYPE =
  "tuple(address l2LegacySharedBridge, address predeployedL2WethAddress, address baseTokenL1Address, tuple(string name, string symbol, uint256 decimals) baseTokenMetadata, tuple(bytes32 assetId, uint256 originChainId, address originToken) baseTokenBridgingData)";

// Merkle tree constants for processLogsAndMessages
// From system-contracts/contracts/Constants.sol: L2_TO_L1_LOGS_MERKLE_TREE_DEPTH = 14 + 1
export const L2_TO_L1_LOGS_MERKLE_TREE_DEPTH = 15;

// keccak256(new bytes(88)) — from Constants.sol:107
export const L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH = "0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

// From IMessageRoot.sol — keccak256(abi.encodePacked(new bytes(96)))
export const CHAIN_TREE_EMPTY_ENTRY_HASH = "0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21";
export const SHARED_ROOT_TREE_EMPTY_HASH = "0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21";

// From MessageHashing.sol:16 — keccak256("zkSync:ChainIdLeaf")
export const CHAIN_ID_LEAF_PADDING = "0x39bc69363bb9e26cf14240de4e22569e95cf175cfbcf1ade1a47a253b4bf7f61";

// L2 bootloader address (used for failed deposit logs)
export const L2_BOOTLOADER_ADDR = "0x0000000000000000000000000000000000008001";

// Event signatures
// GenesisUpgrade(address indexed, L2CanonicalTransaction, uint256 indexed, bytes[])
export const GENESIS_UPGRADE_EVENT_SIG =
  "GenesisUpgrade(address,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),uint256,bytes[])";
export const NEW_PRIORITY_REQUEST_EVENT_SIG =
  "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
export const L1_MESSAGE_SENT_EVENT_SIG = "L1MessageSent(address,bytes32,bytes)";
export const FINALIZE_DEPOSIT_SIG = "finalizeDeposit(uint256,bytes32,bytes)";

// WritePriorityOpParams ABI tuple type for raw decoding NewPriorityRequest events
export const WRITE_PRIORITY_OP_PARAMS_ABI_TYPE =
  "tuple(uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes,uint256[],bytes,bytes)";
