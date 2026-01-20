import { Command } from "commander";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

// Constants
const L2_BRIDGEHUB_ADDRESS = "0x0000000000000000000000000000000000010002";
const DIAMOND_CUT_DATA_ABI_STRING =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";

// ABIs for the contracts we need to interact with
const BRIDGEHUB_ABI = [
  "function getZKChain(uint256 _chainId) view returns (address)",
  "function chainTypeManager(uint256 _chainId) view returns (address)",
];

const ZKCHAIN_ABI = ["function getChainTypeManager() view returns (address)"];

const CTM_ABI = [
  "function initialCutHash() view returns (bytes32)",
  "function initialForceDeploymentHash() view returns (bytes32)",
  "function setChainCreationParams(tuple(address genesisUpgrade, bytes32 genesisBatchHash, uint64 genesisIndexRepeatedStorageChanges, bytes32 genesisBatchCommitment, tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata) diamondCut, bytes forceDeploymentsData) _chainCreationParams)",
  "event NewChainCreationParams(address genesisUpgrade, bytes32 genesisBatchHash, uint64 genesisIndexRepeatedStorageChanges, bytes32 genesisBatchCommitment, tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata) newInitialCut, bytes32 newInitialCutHash, bytes forceDeploymentsData, bytes32 forceDeploymentHash)",
];

interface ChainCreationParams {
  genesisUpgrade: string;
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: number;
  genesisBatchCommitment: string;
  diamondCutData: string;
  forceDeploymentsData: string;
  // Hashes for verification
  initialCutHash: string;
  forceDeploymentHash: string;
}

interface ChainCreationParamsOutput {
  l1: ChainCreationParams;
  gateway?: ChainCreationParams;
}

async function getCTMAddress(
  provider: ethers.providers.Provider,
  bridgehubAddress: string,
  chainId: number
): Promise<string> {
  const bridgehub = new ethers.Contract(bridgehubAddress, BRIDGEHUB_ABI, provider);

  // First get the ZK chain address
  const zkChainAddress = await bridgehub.getZKChain(chainId);
  if (zkChainAddress === ethers.constants.AddressZero) {
    throw new Error(`No ZK chain found for chain ID ${chainId}`);
  }

  console.log(`ZK Chain address: ${zkChainAddress}`);

  // Then get the CTM address from the ZK chain
  const zkChain = new ethers.Contract(zkChainAddress, ZKCHAIN_ABI, provider);
  const ctmAddress = await zkChain.getChainTypeManager();

  if (ctmAddress === ethers.constants.AddressZero) {
    throw new Error(`No CTM found for ZK chain ${zkChainAddress}`);
  }

  console.log(`CTM address: ${ctmAddress}`);
  return ctmAddress;
}

function formatTimestamp(timestamp: number): string {
  const date = new Date(timestamp * 1000);
  return date.toISOString().replace("T", " ").replace(".000Z", " UTC");
}

async function getBlockTimestamp(provider: ethers.providers.Provider, blockNumber: number): Promise<string> {
  try {
    const block = await provider.getBlock(blockNumber);
    return formatTimestamp(block.timestamp);
  } catch {
    return "unknown";
  }
}

async function getLatestChainCreationParams(
  provider: ethers.providers.Provider,
  ctmAddress: string,
  oldestBlock: number = 0,
  mostRecentBlock?: number
): Promise<ChainCreationParams | null> {
  const ctm = new ethers.Contract(ctmAddress, CTM_ABI, provider);

  // Get stored hashes for verification
  const initialCutHash = await ctm.initialCutHash();
  const forceDeploymentHash = await ctm.initialForceDeploymentHash();

  console.log(`Initial cut hash from CTM: ${initialCutHash}`);
  console.log(`Force deployment hash from CTM: ${forceDeploymentHash}`);

  // Query for NewChainCreationParams events
  const filter = ctm.filters.NewChainCreationParams();

  // Get events in chunks, searching backwards from most recent block (or latest if not specified)
  const latestBlock = await provider.getBlockNumber();
  const startingBlock = mostRecentBlock !== undefined ? Math.min(mostRecentBlock, latestBlock) : latestBlock;
  const chunkSize = 10000;
  let foundEvent: ethers.Event | null = null;

  console.log(
    `\nSearching for NewChainCreationParams events from block ${startingBlock} backwards to ${oldestBlock}...`
  );
  if (mostRecentBlock !== undefined) {
    console.log(`  (Latest block on chain: ${latestBlock})`);
  }

  for (let end = startingBlock; end >= oldestBlock && !foundEvent; end -= chunkSize) {
    const start = Math.max(end - chunkSize + 1, oldestBlock);

    // Get timestamps for the block range
    const [startTimestamp, endTimestamp] = await Promise.all([
      getBlockTimestamp(provider, start),
      getBlockTimestamp(provider, end),
    ]);

    console.log(`  Checking blocks ${start} - ${end}`);
    console.log(`    From: ${startTimestamp} (block ${start})`);
    console.log(`    To:   ${endTimestamp} (block ${end})`);

    try {
      const events = await ctm.queryFilter(filter, start, end);
      if (events.length > 0) {
        // Get the latest event from this batch (last one since events are ordered)
        foundEvent = events[events.length - 1];
        console.log(`  ✓ Found ${events.length} event(s), using latest from block ${foundEvent.blockNumber}`);
      }
    } catch (error) {
      // If chunk is too large, try smaller chunks
      console.log(`  Retrying with smaller chunks...`);
      const smallerChunkSize = 1000;
      for (let smallEnd = end; smallEnd >= start && !foundEvent; smallEnd -= smallerChunkSize) {
        const smallStart = Math.max(smallEnd - smallerChunkSize + 1, start);
        try {
          const events = await ctm.queryFilter(filter, smallStart, smallEnd);
          if (events.length > 0) {
            foundEvent = events[events.length - 1];
            console.log(`  ✓ Found ${events.length} event(s), using latest from block ${foundEvent.blockNumber}`);
          }
        } catch (innerError) {
          console.log(`  Warning: Failed to query blocks ${smallStart}-${smallEnd}`);
        }
      }
    }
  }

  if (!foundEvent) {
    console.log("\nNo NewChainCreationParams events found");
    return null;
  }

  const latestEvent = foundEvent;
  console.log(`\nUsing event from block ${latestEvent.blockNumber}`);

  // Parse the event
  const parsedEvent = ctm.interface.parseLog(latestEvent);
  const args = parsedEvent.args;

  // Encode the diamond cut data
  const diamondCutData = ethers.utils.defaultAbiCoder.encode([DIAMOND_CUT_DATA_ABI_STRING], [args.newInitialCut]);

  // Verify hashes match what's stored in CTM
  const computedCutHash = ethers.utils.keccak256(diamondCutData);
  const computedForceDeploymentHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["bytes"], [args.forceDeploymentsData])
  );

  console.log(`Computed cut hash: ${computedCutHash}`);
  console.log(`Event cut hash: ${args.newInitialCutHash}`);

  if (computedCutHash !== initialCutHash) {
    console.warn(
      `Warning: Computed cut hash ${computedCutHash} does not match stored hash ${initialCutHash}. This may indicate the chain creation params have been updated since this event.`
    );
  }

  return {
    genesisUpgrade: args.genesisUpgrade,
    genesisBatchHash: args.genesisBatchHash,
    genesisIndexRepeatedStorageChanges: args.genesisIndexRepeatedStorageChanges.toNumber(),
    genesisBatchCommitment: args.genesisBatchCommitment,
    diamondCutData: diamondCutData,
    forceDeploymentsData: args.forceDeploymentsData,
    initialCutHash: args.newInitialCutHash,
    forceDeploymentHash: args.forceDeploymentHash,
  };
}

async function getChainCreationParamsFromTx(
  provider: ethers.providers.Provider,
  ctmAddress: string,
  txHash: string
): Promise<ChainCreationParams | null> {
  const ctm = new ethers.Contract(ctmAddress, CTM_ABI, provider);

  console.log(`\nFetching transaction ${txHash}...`);

  // Fetch the transaction
  const tx = await provider.getTransaction(txHash);
  if (!tx) {
    throw new Error(`Transaction ${txHash} not found`);
  }

  console.log(`  Transaction found in block ${tx.blockNumber}`);
  console.log(`  To: ${tx.to}`);

  // Verify the transaction was sent to the CTM
  if (tx.to?.toLowerCase() !== ctmAddress.toLowerCase()) {
    console.warn(
      `  Warning: Transaction was sent to ${tx.to}, but CTM address is ${ctmAddress}. Proceeding with decoding anyway...`
    );
  }

  // Decode the transaction input
  let decodedInput;
  try {
    decodedInput = ctm.interface.parseTransaction({ data: tx.data });
  } catch (error) {
    throw new Error(`Failed to decode transaction input: ${error}`);
  }

  if (decodedInput.name !== "setChainCreationParams") {
    throw new Error(
      `Transaction is not a setChainCreationParams call. Found: ${decodedInput.name}`
    );
  }

  console.log(`  Successfully decoded setChainCreationParams call`);

  const chainCreationParams = decodedInput.args._chainCreationParams;

  // Encode the diamond cut data for output
  const diamondCutData = ethers.utils.defaultAbiCoder.encode(
    [DIAMOND_CUT_DATA_ABI_STRING],
    [chainCreationParams.diamondCut]
  );

  // Compute hashes for verification
  const computedCutHash = ethers.utils.keccak256(diamondCutData);
  const computedForceDeploymentHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["bytes"], [chainCreationParams.forceDeploymentsData])
  );

  console.log(`\n  Computed diamond cut hash: ${computedCutHash}`);
  console.log(`  Computed force deployment hash: ${computedForceDeploymentHash}`);

  // Get stored hashes from CTM for verification
  const storedCutHash = await ctm.initialCutHash();
  const storedForceDeploymentHash = await ctm.initialForceDeploymentHash();

  console.log(`\n  Stored diamond cut hash in CTM: ${storedCutHash}`);
  console.log(`  Stored force deployment hash in CTM: ${storedForceDeploymentHash}`);

  // Verify hashes match
  if (computedCutHash !== storedCutHash) {
    console.warn(
      `\n  ⚠ WARNING: Diamond cut hash from transaction (${computedCutHash}) does NOT match stored hash in CTM (${storedCutHash}).`
    );
    console.warn(`    This may indicate the chain creation params have been updated after this transaction.`);
  } else {
    console.log(`\n  ✓ Diamond cut hash matches CTM`);
  }

  if (computedForceDeploymentHash !== storedForceDeploymentHash) {
    console.warn(
      `\n  ⚠ WARNING: Force deployment hash from transaction (${computedForceDeploymentHash}) does NOT match stored hash in CTM (${storedForceDeploymentHash}).`
    );
    console.warn(`    This may indicate the chain creation params have been updated after this transaction.`);
  } else {
    console.log(`  ✓ Force deployment hash matches CTM`);
  }

  return {
    genesisUpgrade: chainCreationParams.genesisUpgrade,
    genesisBatchHash: chainCreationParams.genesisBatchHash,
    genesisIndexRepeatedStorageChanges: chainCreationParams.genesisIndexRepeatedStorageChanges.toNumber
      ? chainCreationParams.genesisIndexRepeatedStorageChanges.toNumber()
      : Number(chainCreationParams.genesisIndexRepeatedStorageChanges),
    genesisBatchCommitment: chainCreationParams.genesisBatchCommitment,
    diamondCutData: diamondCutData,
    forceDeploymentsData: chainCreationParams.forceDeploymentsData,
    initialCutHash: computedCutHash,
    forceDeploymentHash: computedForceDeploymentHash,
  };
}

async function main() {
  const program = new Command();

  program
    .name("fetch-chain-creation-params")
    .description("Fetch the latest chain creation params from L1 and Gateway CTMs")
    .requiredOption("--bridgehub <address>", "L1 Bridgehub address")
    .requiredOption("--era-chain-id <number>", "Era chain ID")
    .option("--l1-rpc <url>", "L1 RPC URL (or set ETH_CLIENT_WEB3_URL env variable)")
    .option("--gateway-rpc <url>", "Gateway RPC URL (if fetching gateway params)")
    .option("--gateway-ctm <address>", "Gateway CTM address (optional, will be fetched from bridgehub if not provided)")
    .option("--l1-oldest-block <number>", "L1 oldest block to search back to (default: 0)", "0")
    .option("--gw-oldest-block <number>", "Gateway oldest block to search back to (default: 0)", "0")
    .option("--l1-most-recent-block <number>", "L1 most recent block to start searching from (default: latest)")
    .option("--gw-most-recent-block <number>", "Gateway most recent block to start searching from (default: latest)")
    .option(
      "--l1-set-chain-creation-params-tx <hash>",
      "L1 transaction hash of setChainCreationParams call (skips event search)"
    )
    .option(
      "--gw-set-chain-creation-params-tx <hash>",
      "Gateway transaction hash of setChainCreationParams call (skips event search)"
    )
    .option("--output <path>", "Output file path for TOML format");

  program.parse(process.argv);

  const options = program.opts();
  const bridgehubAddress = options.bridgehub;
  const eraChainId = parseInt(options.eraChainId);
  const l1RpcUrl = options.l1Rpc || process.env.ETH_CLIENT_WEB3_URL;
  const gatewayRpcUrl = options.gatewayRpc;
  const l1OldestBlock = parseInt(options.l1OldestBlock);
  const gwOldestBlock = parseInt(options.gwOldestBlock);
  const l1MostRecentBlock = options.l1MostRecentBlock ? parseInt(options.l1MostRecentBlock) : undefined;
  const gwMostRecentBlock = options.gwMostRecentBlock ? parseInt(options.gwMostRecentBlock) : undefined;
  const l1SetChainCreationParamsTx = options.l1SetChainCreationParamsTx;
  const gwSetChainCreationParamsTx = options.gwSetChainCreationParamsTx;
  const outputPath = options.output;

  if (!l1RpcUrl) {
    console.error("Error: L1 RPC URL is required. Provide via --l1-rpc or ETH_CLIENT_WEB3_URL env variable.");
    process.exit(1);
  }

  console.log("=".repeat(80));
  console.log("Fetching Chain Creation Params");
  console.log("=".repeat(80));

  // L1 Provider
  const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);

  console.log("\n--- L1 Chain Creation Params ---\n");

  // Get CTM address from L1
  const l1CtmAddress = await getCTMAddress(l1Provider, bridgehubAddress, eraChainId);

  // Get latest chain creation params from L1 CTM
  let l1Params: ChainCreationParams | null;
  if (l1SetChainCreationParamsTx) {
    console.log(`Using provided transaction hash to decode chain creation params...`);
    l1Params = await getChainCreationParamsFromTx(l1Provider, l1CtmAddress, l1SetChainCreationParamsTx);
  } else {
    console.log(`Searching for NewChainCreationParams events...`);
    l1Params = await getLatestChainCreationParams(l1Provider, l1CtmAddress, l1OldestBlock, l1MostRecentBlock);
  }

  if (!l1Params) {
    console.error("Failed to fetch L1 chain creation params");
    process.exit(1);
  }

  console.log("\nL1 Chain Creation Params:");
  console.log(`  Genesis Upgrade: ${l1Params.genesisUpgrade}`);
  console.log(`  Genesis Batch Hash: ${l1Params.genesisBatchHash}`);
  console.log(`  Genesis Index Repeated Storage Changes: ${l1Params.genesisIndexRepeatedStorageChanges}`);
  console.log(`  Genesis Batch Commitment: ${l1Params.genesisBatchCommitment}`);
  console.log(`  Diamond Cut Data Length: ${l1Params.diamondCutData.length} bytes`);
  console.log(`  Force Deployments Data Length: ${l1Params.forceDeploymentsData.length} bytes`);

  const output: ChainCreationParamsOutput = {
    l1: l1Params,
  };

  // Fetch gateway params if gateway RPC is provided
  if (gatewayRpcUrl) {
    console.log("\n--- Gateway Chain Creation Params ---\n");

    const gatewayProvider = new ethers.providers.JsonRpcProvider(gatewayRpcUrl);

    let gatewayCTMAddress = options.gatewayCTM;
    if (!gatewayCTMAddress) {
      // Get CTM address from gateway bridgehub
      console.log(`Using L2 Bridgehub address: ${L2_BRIDGEHUB_ADDRESS}`);
      gatewayCTMAddress = await getCTMAddress(gatewayProvider, L2_BRIDGEHUB_ADDRESS, eraChainId);
    }

    let gatewayParams: ChainCreationParams | null;
    if (gwSetChainCreationParamsTx) {
      console.log(`Using provided transaction hash to decode chain creation params...`);
      gatewayParams = await getChainCreationParamsFromTx(gatewayProvider, gatewayCTMAddress, gwSetChainCreationParamsTx);
    } else {
      console.log(`Searching for NewChainCreationParams events...`);
      gatewayParams = await getLatestChainCreationParams(gatewayProvider, gatewayCTMAddress, gwOldestBlock, gwMostRecentBlock);
    }

    if (gatewayParams) {
      console.log("\nGateway Chain Creation Params:");
      console.log(`  Genesis Upgrade: ${gatewayParams.genesisUpgrade}`);
      console.log(`  Genesis Batch Hash: ${gatewayParams.genesisBatchHash}`);
      console.log(`  Genesis Index Repeated Storage Changes: ${gatewayParams.genesisIndexRepeatedStorageChanges}`);
      console.log(`  Genesis Batch Commitment: ${gatewayParams.genesisBatchCommitment}`);
      console.log(`  Diamond Cut Data Length: ${gatewayParams.diamondCutData.length} bytes`);
      console.log(`  Force Deployments Data Length: ${gatewayParams.forceDeploymentsData.length} bytes`);

      output.gateway = gatewayParams;
    } else {
      console.warn("Warning: Failed to fetch gateway chain creation params");
    }
  }

  // Generate TOML output if requested
  if (outputPath) {
    const tomlContent = generateTomlOutput(output);
    const fullPath = path.resolve(outputPath);
    fs.writeFileSync(fullPath, tomlContent);
    console.log(`\nOutput written to: ${fullPath}`);
  }

  // Also output JSON to console
  console.log("\n--- JSON Output ---\n");
  console.log(JSON.stringify(output, null, 2));
}

function generateTomlOutput(params: ChainCreationParamsOutput): string {
  let toml = `# Chain Creation Params for Verifier-Only Upgrade
# Generated at: ${new Date().toISOString()}

[old_chain_creation_params.l1]
genesis_upgrade = "${params.l1.genesisUpgrade}"
genesis_batch_hash = "${params.l1.genesisBatchHash}"
genesis_index_repeated_storage_changes = ${params.l1.genesisIndexRepeatedStorageChanges}
genesis_batch_commitment = "${params.l1.genesisBatchCommitment}"
diamond_cut_data = "${params.l1.diamondCutData}"
force_deployments_data = "${params.l1.forceDeploymentsData}"
`;

  if (params.gateway) {
    toml += `
[old_chain_creation_params.gateway]
genesis_upgrade = "${params.gateway.genesisUpgrade}"
genesis_batch_hash = "${params.gateway.genesisBatchHash}"
genesis_index_repeated_storage_changes = ${params.gateway.genesisIndexRepeatedStorageChanges}
genesis_batch_commitment = "${params.gateway.genesisBatchCommitment}"
diamond_cut_data = "${params.gateway.diamondCutData}"
force_deployments_data = "${params.gateway.forceDeploymentsData}"
`;
  }

  return toml;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
