import * as fs from "fs";
import * as path from "path";

/** One entry of a forge `broadcast/<script>/<chainId>/run-latest.json` transaction list. */
interface BroadcastTransaction {
  hash: string;
  transactionType: "CREATE" | "CREATE2" | "CALL";
  contractName?: string | null;
  contractAddress?: string | null;
}

export interface ForgeBroadcast {
  transactions: BroadcastTransaction[];
}

/**
 * Reads the latest broadcast forge wrote for `scriptFile` on `chainId`. Forge records every broadcast
 * transaction there, so the tests learn deployed addresses and transaction hashes from the same source a
 * manual `forge script --broadcast` run leaves behind.
 */
export function readLatestBroadcast(projectRoot: string, scriptFile: string, chainId: number): ForgeBroadcast {
  const broadcastPath = path.join(
    projectRoot,
    "broadcast",
    path.basename(scriptFile),
    String(chainId),
    "run-latest.json"
  );
  if (!fs.existsSync(broadcastPath)) {
    throw new Error(`No forge broadcast found at ${broadcastPath}`);
  }
  return JSON.parse(fs.readFileSync(broadcastPath, "utf-8")) as ForgeBroadcast;
}

/** The address of the contract named `contractName` created by the broadcast. */
export function createdContractAddress(broadcast: ForgeBroadcast, contractName: string): string {
  const created = broadcast.transactions.find(
    (tx) => tx.transactionType !== "CALL" && tx.contractName === contractName && tx.contractAddress
  );
  if (!created?.contractAddress) {
    throw new Error(`The broadcast did not create a ${contractName}`);
  }
  return created.contractAddress;
}

/** The hash of the last transaction of the broadcast. */
export function lastTransactionHash(broadcast: ForgeBroadcast): string {
  const last = broadcast.transactions[broadcast.transactions.length - 1];
  if (!last) {
    throw new Error("The broadcast contains no transactions");
  }
  return last.hash;
}
