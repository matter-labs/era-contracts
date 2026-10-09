/**
 * Balance snapshot and assertion helpers for interop tests.
 *
 * Provides utilities for capturing balances, querying ERC20 token balances,
 * approving token spending, and asserting balance deltas.
 */

import { expect } from "chai";
import type { ContractName } from "../core/contracts";
import type { providers } from "ethers";
import { BigNumber, Contract, ethers, Wallet } from "ethers";
import { getAbi } from "../core/contracts";
import { getInteropSourcePrivateKey } from "../core/accounts";
import { L2_NATIVE_TOKEN_VAULT_ADDR } from "../core/const";

// ── Balance snapshot utilities ─────────────────────────────────

export interface BalanceSnapshot {
  native: BigNumber;
  token?: BigNumber;
}

/**
 * Capture a balance snapshot for the default sender on a chain.
 * Optionally captures an ERC20 token balance.
 */
export async function captureBalance(
  provider: providers.JsonRpcProvider,
  tokenAddress?: string
): Promise<BalanceSnapshot> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), provider);
  const native = await provider.getBalance(wallet.address);

  let token: BigNumber | undefined;
  if (tokenAddress) {
    const erc20 = new Contract(tokenAddress, getAbi("TestnetERC20Token"), provider);
    token = await erc20.balanceOf(wallet.address);
  }

  return { native, token };
}

/**
 * Get the native (ETH) balance of an address on a chain.
 */
export async function getNativeBalance(provider: providers.JsonRpcProvider, address: string): Promise<BigNumber> {
  return provider.getBalance(address);
}

/**
 * Get an ERC20 token balance of an address on a chain.
 * Returns 0 if the token contract doesn't exist yet.
 */
export async function getTokenBalance(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  walletAddress: string
): Promise<BigNumber> {
  if (tokenAddress === ethers.constants.AddressZero) return BigNumber.from(0);
  const code = await provider.getCode(tokenAddress);
  if (code === "0x") return BigNumber.from(0);
  const erc20 = new Contract(tokenAddress, getAbi("TestnetERC20Token"), provider);
  return erc20.balanceOf(walletAddress);
}

/**
 * Approve an ERC20 spender.
 */
export async function approveToken(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  spender: string,
  amount: BigNumber
): Promise<void> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), provider);
  const erc20 = new Contract(tokenAddress, getAbi("TestnetERC20Token"), wallet);
  const approveTx = await erc20.approve(spender, amount);
  await approveTx.wait();
  expect((await erc20.allowance(wallet.address, spender)).toString(), "approved allowance").to.equal(amount.toString());
}

/**
 * Approve L2NativeTokenVault to spend tokens.
 */
export async function approveTokenForNtv(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  amount: BigNumber
): Promise<void> {
  await approveToken(provider, tokenAddress, L2_NATIVE_TOKEN_VAULT_ADDR, amount);
}

/**
 * Look up the L2 token address for a given assetId via L2NativeTokenVault.
 */
export async function getTokenAddressForAsset(provider: providers.JsonRpcProvider, assetId: string): Promise<string> {
  const vault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), provider);
  return vault.tokenAddress(assetId);
}

/**
 * Look up the registered assetId for a given L2 token via L2NativeTokenVault.
 */
export async function getAssetIdForToken(provider: providers.JsonRpcProvider, tokenAddress: string): Promise<string> {
  const vault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), provider);
  const assetId: string = await vault.assetId(tokenAddress);
  if (assetId === ethers.constants.HashZero) {
    throw new Error(`Token ${tokenAddress} is not registered in L2NativeTokenVault`);
  }
  return assetId;
}

// ── Balance assertion helpers ──────────────────────────────────

/**
 * Assert that a sender's native balance decreased by exactly `amount + gasCost`.
 * Gas cost is computed from the transaction receipt.
 */
export function expectNativeSpend(
  balBefore: BalanceSnapshot,
  balAfter: BalanceSnapshot,
  amount: BigNumber,
  receipt: ethers.providers.TransactionReceipt,
  label: string
): void {
  const gasCost = receipt.gasUsed.mul(receipt.effectiveGasPrice);
  const expected = balBefore.native.sub(amount).sub(gasCost);
  expect(balAfter.native.eq(expected), `${label}: native balance should decrease by exactly amount + gas`).to.be.true;
}

/**
 * Assert that a balance changed by exactly `expectedDelta`.
 * Positive delta = increase, negative delta = decrease.
 */
export function expectBalanceDelta(before: BigNumber, after: BigNumber, expectedDelta: BigNumber, label: string): void {
  const actualDelta = after.sub(before);
  expect(
    actualDelta.eq(expectedDelta),
    `${label}: expected delta ${expectedDelta.toString()}, got ${actualDelta.toString()}`
  ).to.be.true;
}

/** Assert `txHash` names a mined, successful transaction and return its receipt. */
export async function expectSuccessfulReceipt(
  provider: providers.JsonRpcProvider,
  txHash: string | null,
  label: string
): Promise<providers.TransactionReceipt> {
  expect(txHash, `${label}: transaction must have been submitted`).to.match(/^0x[0-9a-fA-F]{64}$/);
  const receipt = await provider.getTransactionReceipt(txHash!);
  expect(receipt, `${label}: transaction must be mined`).to.exist;
  expect(receipt.status, `${label}: transaction must succeed`).to.equal(1);
  return receipt;
}

/** Assert one event from the expected emitter, then expose its decoded arguments for outcome checks. */
export function expectEvent(
  receipt: providers.TransactionReceipt,
  contract: ContractName,
  address: string,
  eventName: string
): ethers.utils.Result {
  const iface = new ethers.utils.Interface(getAbi(contract));
  const topic = iface.getEventTopic(eventName);
  const logs = receipt.logs.filter(
    (log) => log.address.toLowerCase() === address.toLowerCase() && log.topics[0] === topic
  );
  expect(logs, `${eventName} from ${address}`).to.have.length(1);
  return iface.parseLog(logs[0]).args;
}

interface EthersLikeError {
  argument?: string;
  value?: unknown;
  body?: string;
  data?: unknown;
  error?: unknown;
  receipt?: { blockNumber?: number; status?: number };
  transaction?: {
    data?: string;
    from?: string;
    gasLimit?: BigNumber;
    to?: string;
    value?: BigNumber;
  };
}

export interface CustomErrorExpectation {
  contract: ContractName;
  signature: string;
  args: readonly unknown[];
}

type ExpectedRevert = string | CustomErrorExpectation;

/** Expect `contract`'s custom error `signature` with `args`: the whole ABI-encoded error must match, not only its selector. */
export function customError(
  contract: ContractName,
  signature: string,
  args: readonly unknown[]
): CustomErrorExpectation {
  return { contract, signature, args };
}

function resolveExpectedReason(expectedReason: ExpectedRevert): { expectedData: string; description: string } {
  if (typeof expectedReason === "string") {
    const encodedReason =
      ethers.utils.id("Error(string)").slice(0, 10) +
      ethers.utils.defaultAbiCoder.encode(["string"], [expectedReason]).slice(2);
    return { expectedData: encodedReason, description: expectedReason };
  }

  const { contract, signature, args } = expectedReason;
  const iface = new ethers.utils.Interface(getAbi(contract));
  return {
    expectedData: iface.encodeErrorResult(signature, args),
    description: `${contract}.${signature} with (${args.join(", ")})`,
  };
}

function extractRevertData(err: unknown): string {
  if (typeof err !== "object" || err === null) return "";

  const errorWithData = err as EthersLikeError;
  const nestedErrorData = extractRevertData(errorWithData.error);
  if (nestedErrorData !== "" && nestedErrorData !== "0x") return nestedErrorData;

  // staticPreviewHash decodes the intentional preview revert; other custom errors surface
  // as ethers ABI decoding errors with the original revert bytes in argument="data"/value.
  if (errorWithData.argument === "data" && typeof errorWithData.value === "string") {
    return errorWithData.value;
  }

  const directData = errorWithData.data;
  if (typeof directData === "string" && directData !== "" && directData !== "0x") return directData;

  const nestedData = extractRevertData(directData);
  if (nestedData !== "" && nestedData !== "0x") return nestedData;

  if (errorWithData.body) {
    try {
      const bodyData = extractRevertData(JSON.parse(errorWithData.body));
      if (bodyData !== "" && bodyData !== "0x") return bodyData;
    } catch {
      // Keep checking other fields below.
    }
  }

  if (nestedErrorData) return nestedErrorData;
  if (nestedData) return nestedData;
  if (typeof directData === "string") return directData;
  return "";
}

/**
 * Replays a mined, reverted transaction with `eth_call` on its parent block's state and returns the revert data,
 * or "" when the replay does not revert. Raw `eth_call`, because `JsonRpcProvider.call` resolves with a reverting
 * call's revert bytes (its `checkError("call")`) as if they were return data.
 */
async function replayRevertData(provider: providers.JsonRpcProvider, err: EthersLikeError): Promise<string> {
  const tx = err.transaction;
  const blockNumber = err.receipt?.blockNumber;
  if (err.receipt?.status !== 0 || blockNumber === undefined || !tx?.to || !tx.data) return "";

  try {
    // Interval mining (`--block-time`) can put other transactions before this one in its block; they are not replayed.
    await provider.send("eth_call", [
      {
        to: tx.to,
        from: tx.from,
        data: tx.data,
        value: ethers.utils.hexValue(tx.value ?? 0),
        gas: tx.gasLimit && ethers.utils.hexValue(tx.gasLimit),
      },
      ethers.utils.hexValue(blockNumber - 1),
    ]);
  } catch (callErr: unknown) {
    return extractRevertData(callErr);
  }
  return "";
}

/**
 * Assert that an async call reverts with `expectedReason`: an `Error(string)` reason or a {@link customError}.
 * Needs `provider` when the thrown error carries no revert data, as for a mined transaction that reverted.
 */
export async function expectRevert(
  fn: () => Promise<unknown>,
  label: string,
  expectedReason: ExpectedRevert,
  provider?: providers.JsonRpcProvider
): Promise<void> {
  try {
    await fn();
  } catch (err: unknown) {
    const { expectedData, description } = resolveExpectedReason(expectedReason);
    const msg = err instanceof Error ? err.message : String(err);
    let errorData = extractRevertData(err);
    if ((errorData === "" || errorData === "0x") && provider && typeof err === "object" && err !== null) {
      errorData = await replayRevertData(provider, err as EthersLikeError);
    }
    expect(
      errorData.toLowerCase() === expectedData.toLowerCase(),
      `${label}: revert reason mismatch — expected ${description} in revert data.\nMessage: ${msg.slice(0, 200)}\nData: ${errorData}`
    ).to.be.true;
    return; // reverted as expected
  }
  expect.fail(`${label}: expected revert but call succeeded`);
}

/**
 * Generate a random BigNumber between min and max (inclusive).
 * Useful for randomizing test amounts so tests don't pass only for specific values.
 */
export function randomBigNumber(min: BigNumber, max: BigNumber): BigNumber {
  const range = max.sub(min);
  const randomHex = ethers.utils.hexlify(ethers.utils.randomBytes(32));
  return min.add(BigNumber.from(randomHex).mod(range.add(1)));
}
