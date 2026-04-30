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
import { getInteropTestPrivateKey } from "../core/accounts";
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
  const wallet = new Wallet(getInteropTestPrivateKey(), provider);
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
  const wallet = new Wallet(getInteropTestPrivateKey(), provider);
  const erc20 = new Contract(tokenAddress, getAbi("TestnetERC20Token"), wallet);
  const approveTx = await erc20.approve(spender, amount);
  await approveTx.wait();
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

interface EthersLikeError {
  body?: string;
  data?: unknown;
  error?: unknown;
  receipt?: { blockNumber?: number };
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
}

type ExpectedRevert = string | CustomErrorExpectation;

export function customError(contract: ContractName, signature: string): CustomErrorExpectation {
  return { contract, signature };
}

function resolveExpectedReason(expectedReason: ExpectedRevert): { matchValue: string; description: string } {
  if (typeof expectedReason === "string") {
    return { matchValue: expectedReason, description: expectedReason };
  }

  const selector = new ethers.utils.Interface(getAbi(expectedReason.contract)).getSighash(expectedReason.signature);
  return {
    matchValue: selector,
    description: `${expectedReason.contract}.${expectedReason.signature} (${selector})`,
  };
}

function extractRevertData(err: unknown): string {
  if (typeof err !== "object" || err === null) return "";

  const errorWithData = err as EthersLikeError;
  const nestedErrorData = extractRevertData(errorWithData.error);
  if (nestedErrorData !== "" && nestedErrorData !== "0x") return nestedErrorData;

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

async function extractRevertDataFromCall(provider: providers.JsonRpcProvider, err: EthersLikeError): Promise<string> {
  const tx = err.transaction;
  if (!tx?.to || !tx.data) return "";

  try {
    await provider.call(
      {
        to: tx.to,
        from: tx.from,
        data: tx.data,
        value: tx.value,
        gasLimit: tx.gasLimit,
      },
      err.receipt?.blockNumber
    );
  } catch (callErr: unknown) {
    return extractRevertData(callErr);
  }

  return "";
}

/**
 * Assert that an async call reverts (throws).
 * Optionally match the error message / revert data against a selector or ABI-derived custom error.
 */
export async function expectRevert(
  fn: () => Promise<unknown>,
  label: string,
  expectedReason?: ExpectedRevert,
  provider?: providers.JsonRpcProvider
): Promise<void> {
  try {
    await fn();
  } catch (err: unknown) {
    if (expectedReason) {
      const { matchValue, description } = resolveExpectedReason(expectedReason);
      // Check both the JS error message and the on-chain revert data
      const msg = err instanceof Error ? err.message : String(err);
      const hasReasonInMessage = msg.includes(matchValue);
      const errorWithData = typeof err === "object" && err !== null ? (err as EthersLikeError) : undefined;
      let errorData = extractRevertData(err);
      if ((errorData === "" || errorData === "0x") && provider && errorWithData) {
        const recoveredData = await extractRevertDataFromCall(provider, errorWithData);
        if (recoveredData) {
          errorData = recoveredData;
        }
      }
      const hasReasonInData = errorData.includes(matchValue);
      expect(
        hasReasonInMessage || hasReasonInData,
        `${label}: revert reason mismatch — expected ${description} in message or data.\nMessage: ${msg.slice(0, 200)}\nData: ${String(errorData).slice(0, 200)}`
      ).to.be.true;
    }
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
