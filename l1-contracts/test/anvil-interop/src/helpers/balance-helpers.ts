/**
 * Balance snapshot and assertion helpers for interop tests.
 *
 * Provides utilities for capturing balances, querying ERC20 token balances,
 * approving token spending, and asserting balance deltas.
 */

import { expect } from "chai";
import type { providers } from "ethers";
import { BigNumber, Contract, ethers, Wallet } from "ethers";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_NATIVE_TOKEN_VAULT_ADDR } from "../core/const";

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
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
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
 * Approve L2NativeTokenVault to spend tokens.
 */
export async function approveTokenForNtv(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  amount: BigNumber
): Promise<void> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
  const erc20 = new Contract(tokenAddress, getAbi("TestnetERC20Token"), wallet);
  const approveTx = await erc20.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount);
  await approveTx.wait();
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
export function expectBalanceDelta(
  before: BigNumber,
  after: BigNumber,
  expectedDelta: BigNumber,
  label: string
): void {
  const actualDelta = after.sub(before);
  expect(
    actualDelta.eq(expectedDelta),
    `${label}: expected delta ${expectedDelta.toString()}, got ${actualDelta.toString()}`
  ).to.be.true;
}

/**
 * Assert that an async call reverts (throws).
 * Optionally match the error message against `expectedReason` (substring match).
 */
export async function expectRevert(
  fn: () => Promise<unknown>,
  label: string,
  expectedReason?: string
): Promise<void> {
  try {
    await fn();
  } catch (err: unknown) {
    if (expectedReason) {
      const msg = err instanceof Error ? err.message : String(err);
      expect(msg, `${label}: revert reason mismatch`).to.include(expectedReason);
    }
    return; // reverted as expected
  }
  expect.fail(`${label}: expected revert but call succeeded`);
}
