/**
 * Deploys the branch-local L1 interop contracts on the running L1 Anvil chain:
 *
 *   • BridgeRegistry         — admin-gated daily-limit announce surface
 *   • L1InteropHandler       — verifies L2→L1 bundles via the real Bridgehub
 *                              and lazy-deploys per-(chainId,sender) shadow accounts
 *   • ShadowAccountFactory   — permissionless CREATE2 factory for StealthShadowAccount
 *   • StealthSender          — secret-registration + ownerHash → user reverse map
 *
 * The handler points at the real L1Bridgehub deployed by the rest of the anvil-setup.
 * Proof verification on this Bridgehub goes through `DummyL1MessageRoot`, which always
 * returns true for `_proveL2LeafInclusionRecursive` — so well-shaped (but otherwise
 * fake) proofs are accepted, which is exactly what we want for L1-side coverage of the
 * bundle execution / shadow-account / replay-protection paths.
 *
 * Per-chain `L1ShadowAccount` and `StealthShadowAccount` instances are CREATE2-deployed
 * lazily by the handler and factory respectively, so they don't appear here.
 */

import { ContractFactory, Wallet, providers } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_PRIVATE_KEY, INTEROP_CENTER_ADDR } from "../core/const";

export interface L1InteropContractAddresses {
  /// L1InteropHandler — `executeBundle(...)` entry point + shadow-account predictor.
  l1InteropHandler: string;
  /// BridgeRegistry — `announceBridge(...)` with daily limits and pause gating.
  bridgeRegistry: string;
  /// ShadowAccountFactory — `deploy(...)` for per-(salt,owner) StealthShadowAccount.
  shadowAccountFactory: string;
  /// StealthSender — `register(...)` + `ownerHashOf(...)` for stealth address derivation.
  stealthSender: string;
}

type Logger = (line: string) => void;

/**
 * Deploys the four top-level L1 interop contracts and returns their addresses.
 *
 * Idempotency: each call yields fresh addresses (no CREATE2 here), so re-running
 * after a chain reset is safe. The function does not write to deployment state —
 * the caller is responsible for persisting the returned struct.
 *
 * @param _l1RpcUrl         L1 RPC endpoint
 * @param _bridgehubAddr    Address of the deployed L1Bridgehub (proof verification surface)
 * @param _adminAddr        Address granted DEFAULT_ADMIN_ROLE on BridgeRegistry; defaults to Anvil account #0
 * @param _logger           Optional log sink
 */
export async function deployL1InteropContracts(
  _l1RpcUrl: string,
  _bridgehubAddr: string,
  _adminAddr: string = ANVIL_DEFAULT_ACCOUNT_ADDR,
  _logger?: Logger
): Promise<L1InteropContractAddresses> {
  const log = _logger || console.log;
  const provider = new providers.JsonRpcProvider(_l1RpcUrl);
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);

  // 1. L1InteropHandler — bound to the real Bridgehub and the L2 InteropCenter system addr.
  log("Deploying L1InteropHandler...");
  const handlerFactory = new ContractFactory(
    getAbi("L1InteropHandler"),
    getCreationBytecode("L1InteropHandler"),
    wallet
  );
  const handler = await handlerFactory.deploy(_bridgehubAddr, INTEROP_CENTER_ADDR);
  await handler.deployed();
  log(`  L1InteropHandler: ${handler.address}`);

  // 2. BridgeRegistry — separate admin so role wiring is testable end-to-end.
  log("Deploying BridgeRegistry...");
  const registryFactory = new ContractFactory(
    getAbi("BridgeRegistry"),
    getCreationBytecode("BridgeRegistry"),
    wallet
  );
  const registry = await registryFactory.deploy(_adminAddr);
  await registry.deployed();
  log(`  BridgeRegistry: ${registry.address}`);

  // 3. ShadowAccountFactory — every shadow it deploys will trust the handler above.
  log("Deploying ShadowAccountFactory...");
  const factoryFactory = new ContractFactory(
    getAbi("ShadowAccountFactory"),
    getCreationBytecode("ShadowAccountFactory"),
    wallet
  );
  const factory = await factoryFactory.deploy(handler.address);
  await factory.deployed();
  log(`  ShadowAccountFactory: ${factory.address}`);

  // 4. StealthSender — uses the same handler as the `receiveReturn` gate.
  // In the real design StealthSender lives on L2; for coverage purposes we deploy on L1
  // (the contract has no L1/L2-specific dependencies — only an immutable handler addr).
  log("Deploying StealthSender...");
  const senderFactory = new ContractFactory(
    getAbi("StealthSender"),
    getCreationBytecode("StealthSender"),
    wallet
  );
  const sender = await senderFactory.deploy(handler.address);
  await sender.deployed();
  log(`  StealthSender: ${sender.address}`);

  return {
    l1InteropHandler: handler.address,
    bridgeRegistry: registry.address,
    shadowAccountFactory: factory.address,
    stealthSender: sender.address,
  };
}
