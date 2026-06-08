/**
 * Fund an L2 account on a real ZKsync OS server via an L1 -> L2 ETH deposit.
 *
 * Unlike `src/helpers/l1-deposit-helper.ts` (which manually relays priority requests to a
 * mock-anvil L2), this script only submits the L1 `Bridgehub.requestL2TransactionDirect`
 * deposit and then waits for the running server's `l1_watcher` to pick it up and credit the
 * recipient on L2. Used to bootstrap funded accounts for the atomic-interop demo.
 *
 * Usage:
 *   npx ts-node fund-l2.ts --l1-rpc http://localhost:8545 --l2-rpc http://localhost:3050 \
 *       --bridgehub 0x.. --chain-id 6565 --recipient 0x.. --amount 10 [--pk 0x..]
 */

import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import { getAbi } from "./src/core/contracts";

function parseFlags(argv: string[]): Record<string, string> {
  const flags: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = i + 1 < argv.length && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
      flags[key] = val;
    }
  }
  return flags;
}

async function main(): Promise<void> {
  const f = parseFlags(process.argv.slice(2));
  const l1Rpc = f["l1-rpc"] ?? "http://localhost:8545";
  const l2Rpc = f["l2-rpc"] ?? "http://localhost:3050";
  const bridgehubAddr = f["bridgehub"];
  const chainId = Number(f["chain-id"]);
  const pk = f["pk"] ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  if (!bridgehubAddr || !chainId) throw new Error("missing --bridgehub or --chain-id");

  const l1Provider = new providers.JsonRpcProvider(l1Rpc);
  const l2Provider = new providers.JsonRpcProvider(l2Rpc);
  const l1Wallet = new Wallet(pk, l1Provider);
  const recipient = f["recipient"] ?? l1Wallet.address;
  const amount = ethers.utils.parseEther(f["amount"] ?? "10");

  const bridgehub = new Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Wallet);

  const l2GasLimit = 2_000_000;
  const l2GasPerPubdataByteLimit = 800;
  const gasPrice = 50_000_000_000n; // 50 gwei

  const baseCost: BigNumber = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    l2GasLimit,
    l2GasPerPubdataByteLimit
  );
  const mintValue = baseCost.add(amount);

  const request = {
    chainId,
    mintValue,
    l2Contract: recipient,
    l2Value: amount,
    l2Calldata: "0x",
    l2GasLimit,
    l2GasPerPubdataByteLimit,
    factoryDeps: [],
    refundRecipient: recipient,
  };

  const before = await l2Provider.getBalance(recipient);
  console.log(`[fund] depositing ${ethers.utils.formatEther(amount)} ETH to ${recipient} on chain ${chainId}`);
  console.log(`[fund] baseCost=${baseCost.toString()} mintValue=${mintValue.toString()}`);

  const tx = await bridgehub.requestL2TransactionDirect(request, { value: mintValue, gasLimit: 5_000_000 });
  await tx.wait();
  console.log(`[fund] L1 deposit tx ${tx.hash} mined; waiting for server l1_watcher to credit L2...`);

  const deadline = Date.now() + 120_000;
  for (;;) {
    const bal = await l2Provider.getBalance(recipient);
    if (bal.gt(before)) {
      console.log(`[fund] L2 balance of ${recipient} = ${ethers.utils.formatEther(bal)} ETH (credited)`);
      return;
    }
    if (Date.now() > deadline)
      throw new Error("timed out waiting for L2 credit (is the server processing priority txs?)");
    await new Promise((r) => setTimeout(r, 1500));
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
