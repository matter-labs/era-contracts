/**
 * End-to-end run of the SampleDepositor / SampleWithdrawer example against the anvil-interop chains.
 *
 * The contracts are deployed and driven with the forge scripts from `../script` (exactly what a manual run
 * against Sepolia uses); the pieces a real ZK chain's server would do are taken from the anvil-interop
 * harness: relaying the L1 -> L2 priority transaction and supplying the (mocked) message-inclusion proof for
 * the L1 finalization of each withdrawal bundle.
 *
 * Run from `l1-contracts/`:
 *   yarn example:sample-depositor
 * or, against chains kept running with `--keep-chains`:
 *   ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
 *     yarn hardhat test examples/sample-depositor/test/sample-depositor.spec.ts --network hardhat --no-compile
 */

import { expect } from "chai";
import type { BigNumber } from "ethers";
import { Contract, ethers } from "ethers";
import * as path from "path";
import { DeploymentRunner } from "../../../test/anvil-interop/src/deployment-runner";
import {
  ANVIL_ACCOUNT2_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
  BundleStatus,
  INTEROP_BUNDLE_TUPLE_TYPE,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../../../test/anvil-interop/src/core/const";
import { getAbi } from "../../../test/anvil-interop/src/core/contracts";
import { runForgeScript } from "../../../test/anvil-interop/src/core/forge";
import type { DeploymentState } from "../../../test/anvil-interop/src/core/types";
import {
  createProvider,
  extractAndRelayNewPriorityRequests,
  getChainIdByRole,
  getL2Chain,
} from "../../../test/anvil-interop/src/core/utils";
import { getL1BridgedOut } from "../../../test/anvil-interop/src/helpers/bridged-out-helper";
import { finalizeWithdrawalOnL1 } from "../../../test/anvil-interop/src/helpers/l2-withdrawal-helper";
import { createdContractAddress, lastTransactionHash, readLatestBroadcast } from "./forge-broadcast";

const L1_CONTRACTS_DIR = path.resolve(__dirname, "../../..");
const SCRIPT_DIR = "examples/sample-depositor/script";

const TOKEN_DECIMALS = 18;
/** What the depositor is funded with on L1. */
const FUND_AMOUNT = ethers.utils.parseUnits("1500", TOKEN_DECIMALS);
/** What the depositor bridges to the withdrawer. */
const DEPOSIT_AMOUNT = ethers.utils.parseUnits("1000", TOKEN_DECIMALS);
/** The withdrawals the withdrawer sends back to L1, in order; they must sum to less than `DEPOSIT_AMOUNT`. */
const WITHDRAWALS = [
  { amount: ethers.utils.parseUnits("100", TOKEN_DECIMALS), l1Recipient: ANVIL_RECIPIENT_ADDR },
  { amount: ethers.utils.parseUnits("250", TOKEN_DECIMALS), l1Recipient: ANVIL_RECIPIENT_ADDR },
  { amount: ethers.utils.parseUnits("400", TOKEN_DECIMALS), l1Recipient: ANVIL_ACCOUNT2_ADDR },
];

describe("Example - SampleDepositor (L1) -> SampleWithdrawer (L2) -> multiple withdrawals to L1", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: DeploymentState;
  let chainId: number;
  let l1ChainId: number;
  let l1RpcUrl: string;
  let l2RpcUrl: string;
  let gwRpcUrl: string | undefined;
  let l1Provider: ethers.providers.JsonRpcProvider;
  let l2Provider: ethers.providers.JsonRpcProvider;

  let l1Token: Contract;
  let depositor: string;
  let withdrawer: string;
  let l2Token: Contract;
  let l1TokenAssetId: string;

  async function runScript(scriptFile: string, rpcUrl: string, envVars: Record<string, string>): Promise<void> {
    await runForgeScript({
      scriptPath: `${SCRIPT_DIR}/${scriptFile}`,
      envVars: { PRIVATE_KEY: ANVIL_DEFAULT_PRIVATE_KEY, ...envVars },
      rpcUrl,
      privateKey: ANVIL_DEFAULT_PRIVATE_KEY,
      projectRoot: L1_CONTRACTS_DIR,
      sig: "run()",
    });
  }

  before(async () => {
    state = runner.loadState();
    if (!state.chains?.l1 || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const config = state.chains.config;
    chainId = Number(process.env.SAMPLE_L2_CHAIN_ID) || getChainIdByRole(config, "directSettled");
    l1ChainId = state.chains.l1.chainId;
    l1RpcUrl = state.chains.l1.rpcUrl;
    l2RpcUrl = getL2Chain(state.chains, chainId).rpcUrl;
    // A gateway-settled chain receives its priority transactions through the gateway.
    if (config.find((c) => c.chainId === chainId)?.settlement === "gateway") {
      gwRpcUrl = getL2Chain(state.chains, getChainIdByRole(config, "gateway")).rpcUrl;
    }
    l1Provider = createProvider(l1RpcUrl);
    l2Provider = createProvider(l2RpcUrl);

    console.log(`\n   Deploying the sample contracts (L1 chain ${l1ChainId}, L2 chain ${chainId})...`);
    await runScript("DeploySampleDepositor.s.sol", l1RpcUrl, {
      BRIDGEHUB: state.l1Addresses.bridgehub,
      FUND_AMOUNT: FUND_AMOUNT.toString(),
    });
    const l1Broadcast = readLatestBroadcast(L1_CONTRACTS_DIR, "DeploySampleDepositor.s.sol", l1ChainId);
    l1Token = new Contract(
      createdContractAddress(l1Broadcast, "TestnetERC20Token"),
      getAbi("TestnetERC20Token"),
      l1Provider
    );
    depositor = createdContractAddress(l1Broadcast, "SampleDepositor");

    await runScript("DeploySampleWithdrawer.s.sol", l2RpcUrl, {});
    withdrawer = createdContractAddress(
      readLatestBroadcast(L1_CONTRACTS_DIR, "DeploySampleWithdrawer.s.sol", chainId),
      "SampleWithdrawer"
    );
    console.log(`   Token: ${l1Token.address}\n   SampleDepositor: ${depositor}\n   SampleWithdrawer: ${withdrawer}`);
  });

  it("bridges the ERC20 from the SampleDepositor to the SampleWithdrawer", async () => {
    const l1Ntv = new Contract(state.l1Addresses!.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
    expect((await l1Token.balanceOf(depositor)).eq(FUND_AMOUNT), "depositor should hold the fund amount").to.equal(
      true
    );

    await runScript("BridgeToL2.s.sol", l1RpcUrl, {
      DEPOSITOR: depositor,
      L2_CHAIN_ID: String(chainId),
      L2_RECEIVER: withdrawer,
      AMOUNT: DEPOSIT_AMOUNT.toString(),
    });
    const l1TxHash = lastTransactionHash(readLatestBroadcast(L1_CONTRACTS_DIR, "BridgeToL2.s.sol", l1ChainId));
    const l1Receipt = await l1Provider.getTransactionReceipt(l1TxHash);
    console.log(`   L1 deposit tx: cast run ${l1TxHash} -r ${l1RpcUrl}`);

    // Stand-in for the chain's server: execute the priority transaction(s) the deposit emitted on L1.
    const l2TxHashes = await extractAndRelayNewPriorityRequests(l1Receipt, {
      l1RpcUrl,
      bridgehubAddr: state.l1Addresses!.bridgehub,
      chainId,
      chainRpcUrl: l2RpcUrl,
      gwRpcUrl,
    });
    expect(l2TxHashes.length, "the deposit should produce at least one L2 transaction").to.be.greaterThan(0);

    // The bridged token is deployed by the L2 vault on first arrival.
    const l2Ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), l2Provider);
    const l2TokenAddress: string = await l2Ntv.l2TokenAddress(l1Token.address);
    expect(l2TokenAddress, "the bridged token should exist on L2").to.not.equal(ethers.constants.AddressZero);
    l2Token = new Contract(l2TokenAddress, getAbi("BridgedStandardERC20"), l2Provider);
    console.log(`   Bridged token on L2: ${l2TokenAddress}`);

    l1TokenAssetId = await l1Ntv.assetId(l1Token.address);
    expectEqual(await l2Token.balanceOf(withdrawer), DEPOSIT_AMOUNT, "withdrawer L2 balance");
    expectEqual(await l1Token.balanceOf(depositor), FUND_AMOUNT.sub(DEPOSIT_AMOUNT), "depositor L1 balance");
    expectEqual(await getL1BridgedOut(l1RpcUrl, l1Ntv.address, l1TokenAssetId), DEPOSIT_AMOUNT, "bridgedOut");
  });

  it("withdraws to L1 several times from the SampleWithdrawer", async () => {
    const interopCenter = new ethers.utils.Interface(getAbi("InteropCenter"));
    const l1Nullifier = new Contract(state.l1Addresses!.l1NullifierProxy, getAbi("L1Nullifier"), l1Provider);
    const l1InteropHandler = new Contract(await l1Nullifier.l1InteropHandler(), getAbi("L1InteropHandler"), l1Provider);
    const bundleHashes = new Set<string>();
    let withdrawnTotal = ethers.constants.Zero;

    for (const [index, { amount, l1Recipient }] of WITHDRAWALS.entries()) {
      console.log(
        `\n   Withdrawal ${index + 1}/${WITHDRAWALS.length}: ${ethers.utils.formatUnits(amount)} -> ${l1Recipient}`
      );
      const recipientBefore: BigNumber = await l1Token.balanceOf(l1Recipient);

      await runScript("WithdrawToL1.s.sol", l2RpcUrl, {
        WITHDRAWER: withdrawer,
        L1_TOKEN: l1Token.address,
        AMOUNT: amount.toString(),
        L1_RECIPIENT: l1Recipient,
      });
      const l2TxHash = lastTransactionHash(readLatestBroadcast(L1_CONTRACTS_DIR, "WithdrawToL1.s.sol", chainId));
      console.log(`   L2 withdraw tx: cast run ${l2TxHash} -r ${l2RpcUrl}`);

      // The bundle the InteropCenter emitted is what gets executed on L1, byte for byte.
      const receipt = await l2Provider.getTransactionReceipt(l2TxHash);
      const sent = receipt.logs
        .map((log) => {
          try {
            return interopCenter.parseLog(log);
          } catch {
            return undefined;
          }
        })
        .find((parsed) => parsed?.name === "InteropBundleSent");
      if (!sent) {
        throw new Error(`InteropBundleSent not found in ${l2TxHash}`);
      }
      const bundleHash: string = sent.args.interopBundleHash;
      const bundleData = ethers.utils.defaultAbiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [sent.args.interopBundle]);
      expect(bundleHashes.has(bundleHash), "each withdrawal should produce a distinct bundle").to.equal(false);
      bundleHashes.add(bundleHash);

      // Stand-in for the chain's server + the L1 finalizer: prove the bundle's inclusion and execute it on L1.
      const result = await finalizeWithdrawalOnL1(l1RpcUrl, state.l1Addresses!, {
        l2TxHash,
        chainId,
        amount,
        l1Recipient,
        tokenAddress: l1Token.address,
        bundleData,
      });
      expect(result.success, `L1 finalization should succeed: ${result.errorMessage ?? ""}`).to.equal(true);

      withdrawnTotal = withdrawnTotal.add(amount);
      expectEqual((await l1Token.balanceOf(l1Recipient)).sub(recipientBefore), amount, "recipient L1 balance delta");
      expect(await l1InteropHandler.bundleStatus(bundleHash), "bundle status").to.equal(BundleStatus.FullyExecuted);
    }

    const sampleWithdrawer = new Contract(
      withdrawer,
      ["function withdrawalCount() view returns (uint256)"],
      l2Provider
    );
    expectEqual(await sampleWithdrawer.withdrawalCount(), ethers.BigNumber.from(WITHDRAWALS.length), "withdrawalCount");
    expectEqual(await l2Token.balanceOf(withdrawer), DEPOSIT_AMOUNT.sub(withdrawnTotal), "withdrawer L2 balance");
    expectEqual(
      await getL1BridgedOut(l1RpcUrl, state.l1Addresses!.l1NativeTokenVault, l1TokenAssetId),
      DEPOSIT_AMOUNT.sub(withdrawnTotal),
      "bridgedOut"
    );
  });
});

function expectEqual(actual: BigNumber, expected: BigNumber, label: string): void {
  expect(actual.eq(expected), `${label}: expected ${expected.toString()}, got ${actual.toString()}`).to.equal(true);
}
