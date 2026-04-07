import type { MultiChainTokenTransferResult } from "../core/types";
import type { PrivateInteropAddresses } from "./private-interop-deployer";
import { executeInteropTokenTransfer } from "./token-transfer";

type Logger = (line: string) => void;

export interface PrivateTokenTransferOptions {
  sourceChainId: number;
  targetChainId: number;
  amount: string;
  sourceTokenAddress: string;
  sourceAddresses: PrivateInteropAddresses;
  targetAddresses: PrivateInteropAddresses;
  logger?: Logger;
}

/**
 * Execute a private interop token transfer between two chains.
 * Delegates to the shared executeInteropTokenTransfer with private addresses.
 */
export async function executePrivateTokenTransfer(
  options: PrivateTokenTransferOptions
): Promise<MultiChainTokenTransferResult> {
  return executeInteropTokenTransfer({
    sourceChainId: options.sourceChainId,
    targetChainId: options.targetChainId,
    amount: options.amount,
    sourceTokenAddress: options.sourceTokenAddress,
    sourceAddresses: options.sourceAddresses,
    targetAddresses: options.targetAddresses,
    logger: options.logger,
  });
}
