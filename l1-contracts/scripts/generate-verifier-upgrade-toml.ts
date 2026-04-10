import { Command } from "commander";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";

// ============================================================================
// Environment configs — all the constants that don't change between upgrades
// ============================================================================

interface EnvConfig {
  eraChainId: number;
  testnetVerifier: boolean;
  bridgehubProxy: string;
  tokenWeth: string;
  gatewayChainId: number;
  l1RpcDefault: string;
  gatewayRpcDefault: string;
  // These are "unused" by VerifierOnlyUpgrade but required by the parent class
  governanceSecurityCouncil: string;
  l1BytecodesSupplier: string;
  rollupDaManager: string;
  // Gateway state transition addresses
  gateway: {
    ctmProxy: string;
    ctmProxyAdmin: string;
    rollupDaManager: string;
    rollupSlDaValidator: string;
  };
}

const ENV_CONFIGS: Record<string, EnvConfig> = {
  stage: {
    eraChainId: 270,
    testnetVerifier: true,
    bridgehubProxy: "0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE",
    tokenWeth: "0x7b79995e5f793a07bc00c21412e50ecae098e7f9",
    gatewayChainId: 123,
    l1RpcDefault: "https://gateway.tenderly.co/public/sepolia",
    gatewayRpcDefault: "", // Must be provided via env var
    governanceSecurityCouncil: "0xed04b1ac422251851a3EC953Ff4395e5c2443647",
    l1BytecodesSupplier: "0x662B8fE285BB3aab483e75Ec46136e01aaa154f9",
    rollupDaManager: "0xeb7c0daaddfb52afa05400b489e7497b271d6122",
    gateway: {
      ctmProxy: "0x7f5401a0a0340f6a68fe3162e7bb3a57e262d18e",
      ctmProxyAdmin: "0x0f7bef9694575a0e149dad6808d69f678746608b",
      rollupDaManager: "0x064ac968CCad1948fceE025fD59c20b153c88072",
      rollupSlDaValidator: "0x719A5aE8dF7468C7E1C22278eD3fD472e9904604",
    },
  },
  mainnet: {
    eraChainId: 324,
    testnetVerifier: false,
    bridgehubProxy: "0x303a465B659cBB0ab36eE643eA362c509EEb5213",
    tokenWeth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    gatewayChainId: 9075,
    l1RpcDefault: "https://gateway.tenderly.co/public/mainnet",
    gatewayRpcDefault: "", // Must be provided via env var
    governanceSecurityCouncil: "0xC2aFcF132a7c5d89F4803D4729F482FbBeb0685b",
    l1BytecodesSupplier: "0x0000000000000000000000000000000000000000", // TODO: fill in
    rollupDaManager: "0x0000000000000000000000000000000000000000", // TODO: fill in
    gateway: {
      ctmProxy: "0x0000000000000000000000000000000000000000", // TODO: fill in
      ctmProxyAdmin: "0x0000000000000000000000000000000000000000",
      rollupDaManager: "0x0000000000000000000000000000000000000000",
      rollupSlDaValidator: "0x0000000000000000000000000000000000000000",
    },
  },
};

// ============================================================================
// ABIs
// ============================================================================

const BRIDGEHUB_ABI = [
  "function owner() view returns (address)",
  "function getZKChain(uint256) view returns (address)",
  "function chainTypeManager(uint256) view returns (address)",
];

const CTM_ABI = [
  "function protocolVersion() view returns (uint256)",
  "function initialCutHash() view returns (bytes32)",
  "function initialForceDeploymentHash() view returns (bytes32)",
  "function getChainCreationParams() view returns (tuple(address,bytes32,uint64,bytes32,tuple(tuple(address,uint8,bool,bytes4[])[],address,bytes),bytes))",
];

const ZKCHAIN_ABI = [
  "function getProtocolVersion() view returns (uint256)",
];

const L2_BRIDGEHUB_ADDRESS = "0x0000000000000000000000000000000000010002";

const DIAMOND_CUT_DATA_ABI_STRING =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";

const CTM_EVENTS_ABI = [
  "event NewChainCreationParams(address genesisUpgrade, bytes32 genesisBatchHash, uint64 genesisIndexRepeatedStorageChanges, bytes32 genesisBatchCommitment, tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata) newInitialCut, bytes32 newInitialCutHash, bytes forceDeploymentsData, bytes32 forceDeploymentHash)",
];

// ============================================================================
// Chain data fetching
// ============================================================================

interface ChainCreationParamsData {
  genesisUpgrade: string;
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: number;
  genesisBatchCommitment: string;
  diamondCutData: string;
  forceDeploymentsData: string;
}

async function fetchChainCreationParams(
  provider: ethers.providers.Provider,
  ctmAddress: string
): Promise<ChainCreationParamsData | null> {
  const ctm = new ethers.Contract(ctmAddress, [...CTM_ABI, ...CTM_EVENTS_ABI], provider);

  // Search for the latest NewChainCreationParams event
  const filter = ctm.filters.NewChainCreationParams();
  const latestBlock = await provider.getBlockNumber();
  const chunkSize = 10000;
  let foundEvent: ethers.Event | null = null;

  console.log(`  Searching for NewChainCreationParams events...`);

  for (let end = latestBlock; end >= 0 && !foundEvent; end -= chunkSize) {
    const start = Math.max(end - chunkSize + 1, 0);
    try {
      const events = await ctm.queryFilter(filter, start, end);
      if (events.length > 0) {
        foundEvent = events[events.length - 1];
        console.log(`  Found event in block ${foundEvent.blockNumber}`);
      }
    } catch {
      // Try smaller chunks
      const smallerChunk = 1000;
      for (let se = end; se >= start && !foundEvent; se -= smallerChunk) {
        const ss = Math.max(se - smallerChunk + 1, start);
        try {
          const events = await ctm.queryFilter(filter, ss, se);
          if (events.length > 0) {
            foundEvent = events[events.length - 1];
          }
        } catch { /* skip */ }
      }
    }
  }

  if (!foundEvent) {
    console.log("  No NewChainCreationParams events found");
    return null;
  }

  const parsed = ctm.interface.parseLog(foundEvent);
  const args = parsed.args;

  const diamondCutData = ethers.utils.defaultAbiCoder.encode(
    [DIAMOND_CUT_DATA_ABI_STRING],
    [args.newInitialCut]
  );

  return {
    genesisUpgrade: args.genesisUpgrade,
    genesisBatchHash: args.genesisBatchHash,
    genesisIndexRepeatedStorageChanges: args.genesisIndexRepeatedStorageChanges.toNumber(),
    genesisBatchCommitment: args.genesisBatchCommitment,
    diamondCutData,
    forceDeploymentsData: args.forceDeploymentsData,
  };
}

async function readOnChainState(
  l1Provider: ethers.providers.Provider,
  envConfig: EnvConfig
) {
  const bridgehub = new ethers.Contract(envConfig.bridgehubProxy, BRIDGEHUB_ABI, l1Provider);

  console.log("Reading on-chain state...");

  // Owner
  const owner = await bridgehub.owner();
  console.log(`  Owner: ${owner}`);

  // CTM address
  const zkChainAddr = await bridgehub.getZKChain(envConfig.eraChainId);
  console.log(`  ZKChain: ${zkChainAddr}`);

  const ctmAddr = await bridgehub.chainTypeManager(envConfig.eraChainId);
  console.log(`  CTM: ${ctmAddr}`);

  // Protocol version from ZKChain
  const zkChain = new ethers.Contract(zkChainAddr, ZKCHAIN_ABI, l1Provider);
  const protocolVersion = await zkChain.getProtocolVersion();
  const protocolVersionHex = "0x" + protocolVersion.toHexString().replace("0x", "");
  console.log(`  Protocol version: ${protocolVersionHex}`);

  // Chain creation params from L1
  console.log("\nFetching L1 chain creation params...");
  const l1Params = await fetchChainCreationParams(l1Provider, ctmAddr);

  return {
    owner,
    ctmAddr,
    protocolVersion: protocolVersionHex,
    protocolVersionNum: protocolVersion,
    l1ChainCreationParams: l1Params,
  };
}

// ============================================================================
// TOML generation
// ============================================================================

function generateToml(
  envConfig: EnvConfig,
  onChain: Awaited<ReturnType<typeof readOnChainState>>,
  gwParams: ChainCreationParamsData | null,
): string {
  const oldVersion = onChain.protocolVersion;
  const newVersionNum = onChain.protocolVersionNum.add(1);
  const newVersion = "0x" + newVersionNum.toHexString().replace("0x", "");
  const salt = "0x" + crypto.randomBytes(32).toString("hex");

  let toml = `# Auto-generated verifier-only upgrade TOML
# Generated at: ${new Date().toISOString()}
# Environment: ${envConfig.testnetVerifier ? "stage" : "mainnet"}

era_chain_id = ${envConfig.eraChainId}
testnet_verifier = ${envConfig.testnetVerifier}
governance_upgrade_timer_initial_delay = 0
owner_address = "${onChain.owner}"
support_l2_legacy_shared_bridge_test = false

old_protocol_version = ${oldVersion}

priority_txs_l2_gas_limit = 2000000
max_expected_l1_gas_price = 50000000000

[contracts]
governance_min_delay = 0
max_number_of_chains = 100
create2_factory_salt = "${salt}"
create2_factory_addr = "0x4e59b44847b379578588920cA78FbF26c0B4956C"

validator_timelock_execution_delay = 0
genesis_root = "0x0000000000000000000000000000000000000000000000000000000000000000"
genesis_rollup_leaf_index = 0
genesis_batch_commitment = "0x0000000000000000000000000000000000000000000000000000000000000000"
recursion_node_level_vk_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"
recursion_leaf_level_vk_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"
recursion_circuits_set_vks_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"
priority_tx_max_gas_limit = 72000000
diamond_init_pubdata_pricing_mode = 0
diamond_init_batch_overhead_l1_gas = 1000000
diamond_init_max_pubdata_per_batch = 120000
diamond_init_max_l2_gas_per_batch = 80000000
diamond_init_priority_tx_max_pubdata = 99000
diamond_init_minimal_l2_gas_price = 250000000
bootloader_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"
default_aa_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"
evm_emulator_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"

bridgehub_proxy_address = "${envConfig.bridgehubProxy}"
rollup_da_manager = "${envConfig.rollupDaManager}"
governance_security_council_address = "${envConfig.governanceSecurityCouncil}"
l1_bytecodes_supplier_addr = "${envConfig.l1BytecodesSupplier}"

latest_protocol_version = ${newVersion}

[tokens]
token_weth_address = "${envConfig.tokenWeth}"

[gateway]
chain_id = ${envConfig.gatewayChainId}

[gateway.gateway_state_transition]
chain_type_manager_proxy_addr = "${envConfig.gateway.ctmProxy}"
chain_type_manager_proxy_admin = "${envConfig.gateway.ctmProxyAdmin}"
rollup_da_manager = "${envConfig.gateway.rollupDaManager}"
rollup_sl_da_validator = "${envConfig.gateway.rollupSlDaValidator}"
`;

  // Append L1 chain creation params
  if (onChain.l1ChainCreationParams) {
    const p = onChain.l1ChainCreationParams;
    toml += `
[old_chain_creation_params.l1]
genesis_upgrade = "${p.genesisUpgrade}"
genesis_batch_hash = "${p.genesisBatchHash}"
genesis_index_repeated_storage_changes = ${p.genesisIndexRepeatedStorageChanges}
genesis_batch_commitment = "${p.genesisBatchCommitment}"
diamond_cut_data = "${p.diamondCutData}"
force_deployments_data = "${p.forceDeploymentsData}"
`;
  }

  // Append Gateway chain creation params
  if (gwParams) {
    toml += `
[old_chain_creation_params.gateway]
genesis_upgrade = "${gwParams.genesisUpgrade}"
genesis_batch_hash = "${gwParams.genesisBatchHash}"
genesis_index_repeated_storage_changes = ${gwParams.genesisIndexRepeatedStorageChanges}
genesis_batch_commitment = "${gwParams.genesisBatchCommitment}"
diamond_cut_data = "${gwParams.diamondCutData}"
force_deployments_data = "${gwParams.forceDeploymentsData}"
`;
  }

  return toml;
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const program = new Command();

  program
    .name("generate-verifier-upgrade-toml")
    .description("Generate a complete upgrade TOML for verifier-only upgrades by reading on-chain state")
    .requiredOption("--env <environment>", "Environment: stage or mainnet")
    .option("--l1-rpc <url>", "L1 RPC URL (defaults per environment)")
    .option("--gateway-rpc <url>", "Gateway RPC URL")
    .option("--output <path>", "Output TOML file path", "upgrade-input.toml");

  program.parse(process.argv);
  const opts = program.opts();

  const envName = opts.env as string;
  const envConfig = ENV_CONFIGS[envName];
  if (!envConfig) {
    console.error(`Unknown environment: ${envName}. Use 'stage' or 'mainnet'.`);
    process.exit(1);
  }

  const l1RpcUrl = opts.l1Rpc || process.env.L1_RPC_URL || envConfig.l1RpcDefault;
  const gatewayRpcUrl = opts.gatewayRpc || process.env.GATEWAY_RPC_URL || envConfig.gatewayRpcDefault;

  console.log("=".repeat(60));
  console.log(`Generating verifier upgrade TOML for: ${envName}`);
  console.log("=".repeat(60));
  console.log(`  L1 RPC: ${l1RpcUrl}`);
  console.log(`  Gateway RPC: ${gatewayRpcUrl || "(not set)"}`);
  console.log("");

  const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);
  const onChain = await readOnChainState(l1Provider, envConfig);

  // Fetch gateway chain creation params if gateway RPC is provided
  let gwParams: ChainCreationParamsData | null = null;
  if (gatewayRpcUrl && envConfig.gatewayChainId !== 0) {
    console.log("\nFetching Gateway chain creation params...");
    const gwProvider = new ethers.providers.JsonRpcProvider(gatewayRpcUrl);
    const gwBridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDRESS, BRIDGEHUB_ABI, gwProvider);
    const gwCtmAddr = await gwBridgehub.chainTypeManager(envConfig.eraChainId);
    console.log(`  Gateway CTM: ${gwCtmAddr}`);
    gwParams = await fetchChainCreationParams(gwProvider, gwCtmAddr);
  }

  const toml = generateToml(envConfig, onChain, gwParams);

  const outputPath = path.resolve(opts.output);
  fs.writeFileSync(outputPath, toml);
  console.log(`\nTOML written to: ${outputPath}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
