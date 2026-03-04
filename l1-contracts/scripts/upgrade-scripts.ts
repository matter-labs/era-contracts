import { Command } from "commander";
import { Provider as ZkSyncProvider } from "zksync-ethers";
import { ethers } from "ethers";

// eslint-disable-next-line @typescript-eslint/no-var-requires
const TESTNET_PROTOCOL_UPGRADE_HANDLER_ABI = require("./abi/TestnetProtocolUpgradeHandler.json").abi;

const program = new Command();

// ABI type used to decode the upgrade proposal message.
const UPGRADE_PROPOSAL_ABI_TYPE = "tuple(tuple(address target, uint256 value, bytes data)[], address, bytes32)";
const L1_MESSAGE_SENT_TOPIC = ethers.utils.id("L1MessageSent(address,bytes32,bytes)");

// Helper function to extract messages sent from the tx receipt using both the log address and topic[0].
// Event signature: L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message)
function extractMessagesSent(txRec: ethers.providers.TransactionReceipt): string[] {
  return txRec.logs
    .filter(
      (log) =>
        log.address.toLowerCase() === "0x0000000000000000000000000000000000008008" &&
        log.topics[0] === L1_MESSAGE_SENT_TOPIC
    )
    .map((log) => ethers.utils.defaultAbiCoder.decode(["bytes"], log.data)[0]);
}

program.name("protocol-upgrade").description("CLI tool to start or execute a protocol upgrade").version("1.0.0");

program
  .command("startUpgrade")
  .description("Starts the protocol upgrade on L1 by submitting the upgrade proposal")
  .requiredOption("--l2tx <txHash>", "L2 transaction hash")
  .requiredOption("--protocolUpgradeHandler <address>", "Protocol upgrade handler contract address")
  .requiredOption("--l2-rpc-url <url>", "L2 RPC URL for zkSync Stage2 provider")
  .requiredOption("--l1-rpc-url <url>", "L1 RPC URL (e.g., Sepolia) provider")
  .requiredOption("--pk <privateKey>", "L1 wallet private key")
  .option("--message-id <number>", "ID (index) of the message from the transaction receipt to use", "0")
  .action(async (options) => {
    try {
      const { l2tx, protocolUpgradeHandler, l2RpcUrl, l1RpcUrl, pk, messageId } = options;

      // Initialize providers and wallet.
      const zksyncProvider = new ZkSyncProvider(l2RpcUrl);
      const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);
      const l1Wallet = new ethers.Wallet(pk, l1Provider);

      // Instantiate the protocol upgrade handler contract.
      const l1ProtocolUpgradeHandler = new ethers.Contract(
        protocolUpgradeHandler.toLowerCase(),
        TESTNET_PROTOCOL_UPGRADE_HANDLER_ABI,
        l1Wallet
      );

      // Fetch the L2 transaction receipt and extract messages.
      const txRec = await zksyncProvider.getTransactionReceipt(l2tx);
      const msgs = extractMessagesSent(txRec);
      const msgId = parseInt(messageId, 10);

      if (!msgs || msgs.length <= msgId) {
        throw new Error(`Message with id ${msgId} not found in the provided transaction receipt.`);
      }
      const upgradeMsg = msgs[msgId];

      // Get the message proof from the zkSync provider.
      const proof = await zksyncProvider.getLogProof(txRec.transactionHash, msgId);

      // Decode the upgrade proposal from the message.
      const decodedUpgradeProposal = ethers.utils.defaultAbiCoder.decode([UPGRADE_PROPOSAL_ABI_TYPE], upgradeMsg)[0];

      // Call startUpgrade on the handler contract.
      const tx = await l1ProtocolUpgradeHandler.startUpgrade(
        txRec.l1BatchNumber,
        proof.id,
        txRec.l1BatchTxIndex,
        proof.proof,
        decodedUpgradeProposal
      );
      console.log("startUpgrade transaction sent:", tx);
    } catch (err) {
      console.error("Error in startUpgrade:", err);
      process.exit(1);
    }
  });

program
  .command("executeUpgrade")
  .description("Executes the protocol upgrade on L1 using the upgrade proposal")
  .requiredOption("--l2tx <txHash>", "L2 transaction hash")
  .requiredOption("--protocolUpgradeHandler <address>", "Protocol upgrade handler contract address")
  .requiredOption("--l2-rpc-url <url>", "L2 RPC URL for zkSync Stage2 provider")
  .requiredOption("--l1-rpc-url <url>", "L1 RPC URL (e.g., Sepolia) provider")
  .requiredOption("--pk <privateKey>", "L1 wallet private key")
  .option("--message-id <number>", "ID (index) of the message from the transaction receipt to use", "0")
  .action(async (options) => {
    try {
      const { l2tx, protocolUpgradeHandler, l2RpcUrl, l1RpcUrl, pk, messageId } = options;

      // Initialize providers and wallet.
      const zksyncProvider = new ZkSyncProvider(l2RpcUrl);
      const l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);
      const l1Wallet = new ethers.Wallet(pk, l1Provider);

      // Instantiate the protocol upgrade handler contract.
      const l1ProtocolUpgradeHandler = new ethers.Contract(
        protocolUpgradeHandler.toLowerCase(),
        TESTNET_PROTOCOL_UPGRADE_HANDLER_ABI,
        l1Wallet
      );

      // Fetch the L2 transaction receipt and extract messages.
      const txRec = await zksyncProvider.getTransactionReceipt(l2tx);
      const msgs = extractMessagesSent(txRec);
      const msgId = parseInt(messageId, 10);

      if (!msgs || msgs.length <= msgId) {
        throw new Error(`Message with id ${msgId} not found in the provided transaction receipt.`);
      }
      const upgradeMsg = msgs[msgId];

      // Decode the upgrade proposal from the message.
      const decodedUpgradeProposal = ethers.utils.defaultAbiCoder.decode([UPGRADE_PROPOSAL_ABI_TYPE], upgradeMsg)[0];

      // Call execute on the handler contract.
      const tx = await l1ProtocolUpgradeHandler.execute(decodedUpgradeProposal);
      console.log("executeUpgrade transaction sent:", tx);
    } catch (err) {
      console.error("Error in executeUpgrade:", err);
      process.exit(1);
    }
  });

program.parse(process.argv);
