// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import * as fs from "fs";
import * as path from "path";

export const testConfigPath = process.env.ZKSYNC_ENV
  ? path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant")
  : "./test/test_config/constant";
export const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export const SYSTEM_UPGRADE_L2_TX_TYPE = 254;
export const ADDRESS_ONE = "0x0000000000000000000000000000000000000001";
export const ETH_ADDRESS_IN_CONTRACTS = ADDRESS_ONE;
export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
export const L2_BRIDGEHUB_ADDRESS = "0x0000000000000000000000000000000000010002";
export const L2_ASSET_ROUTER_ADDRESS = "0x0000000000000000000000000000000000010003";
export const L2_NATIVE_TOKEN_VAULT_ADDRESS = "0x0000000000000000000000000000000000010004";
export const L2_MESSAGE_ROOT_ADDRESS = "0x0000000000000000000000000000000000010005";
export const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
export const EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

export const HYPERCHAIN_COMMITMENT_ABI_STRING =
  "tuple(uint256 totalBatchesExecuted, uint256 totalBatchesVerified, uint256 totalBatchesCommitted, bytes32 l2SystemContractsUpgradeTxHash, uint256 l2SystemContractsUpgradeBatchNumber, bytes32[] batchHashes, tuple(uint256 nextLeafIndex, uint256 startIndex, uint256 unprocessedIndex, bytes32[] sides) priorityTree)";
export const STORED_BATCH_INFO_ABI_STRING =
  "tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment)";
export const COMMIT_BATCH_INFO_ABI_STRING =
  "tuple(uint64 batchNumber, uint64 timestamp, uint64 indexRepeatedStorageChanges, bytes32 newStateRoot, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 bootloaderHeapInitialContentsHash, bytes32 eventsQueueStateHash, bytes systemLogs, bytes operatorDAInput)";
export const PRIORITY_OPS_BATCH_INFO_ABI_STRING =
  "tuple(bytes32[] leftPath, bytes32[] rightPath, bytes32[] itemHashes)";
export const DIAMOND_CUT_DATA_ABI_STRING =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";
export const FORCE_DEPLOYMENT_ABI_STRING =
  "tuple(bytes32 bytecodeHash, address newAddress, bool callConstructor, uint256 value, bytes input)[]";
export const BRIDGEHUB_CTM_ASSET_DATA_ABI_STRING = "tuple(uint256 chainId, bytes ctmData, bytes chainData)";
export const FIXED_FORCE_DEPLOYMENTS_DATA_ABI_STRING =
  "tuple(uint256 l1ChainId, uint256 eraChainId, address l1AssetRouter, bytes32 l2TokenProxyBytecodeHash, address aliasedL1Governance, uint256 maxNumberOfZKChains, bytes32 bridgehubBytecodeHash, bytes32 l2AssetRouterBytecodeHash, bytes32 l2NtvBytecodeHash, bytes32 messageRootBytecodeHash)";
export const ADDITIONAL_FORCE_DEPLOYMENTS_DATA_ABI_STRING = "tuple(bytes32 baseTokenAssetId, address l2Weth)";
