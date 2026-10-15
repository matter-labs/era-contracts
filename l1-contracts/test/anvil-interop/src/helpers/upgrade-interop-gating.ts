import type { providers } from "ethers";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
  ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  DEFAULT_TX_GAS_LIMIT,
  L2_BRIDGEHUB_ADDR,
  LEGACY_CHAIN_REGISTRATION_ENCODING_VERSION,
} from "../core/const";
import { getInteropSourceAddress } from "../core/accounts";
import type { CoreDeployedAddresses } from "../core/types";
import { impersonateAndRun, relayPriorityRequestsToChain } from "../core/utils";
import { customError, expectRevert } from "./balance-helpers";
import { encodeEvmChainAddress } from "./erc7930";
import { getInteropProtocolFee, sendInteropMessage } from "./interop-helpers";

/** An upgraded chain, with its L2. */
export type GatedChain = { chainId: number; diamondProxy: string; provider: providers.JsonRpcProvider };

export type InteropGatingContext = {
  l1Provider: providers.JsonRpcProvider;
  // Owns the chains' `ChainAdminOwnable` admins and pays for the legacy registration.
  chainAdminOwner: ethers.Wallet;
  l1Addresses: CoreDeployedAddresses;
};

/**
 * Before the upgrade: registers `_peer` on `_chain`'s L2Bridgehub through the consent-free registration of the
 * release being upgraded, so that `_chain` starts with a legacy pair
 * ({protocol-docs/interop-gating.md#legacy-registrations}). Uses its paid deposit form, which the current ABIs
 * cover, so `_chain`'s base token must be ether.
 */
export async function registerLegacyInteropPair(
  _context: InteropGatingContext,
  _chain: GatedChain,
  _peer: GatedChain
): Promise<void> {
  const payer = _context.chainAdminOwner;
  const bridgehub = new ethers.Contract(_context.l1Addresses.bridgehub, getAbi("L1Bridgehub"), payer);
  const l2GasLimit = ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT;
  const mintValue = await bridgehub.l2TransactionBaseCost(
    _chain.chainId,
    ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
    l2GasLimit,
    ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );
  const tx = await bridgehub.requestL2TransactionTwoBridges(
    {
      chainId: _chain.chainId,
      mintValue,
      l2Value: 0,
      l2GasLimit,
      l2GasPerPubdataByteLimit: ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      refundRecipient: payer.address,
      secondBridgeAddress: _context.l1Addresses.chainRegistrationSender,
      secondBridgeValue: 0,
      secondBridgeCalldata: ethers.utils.hexConcat([
        LEGACY_CHAIN_REGISTRATION_ENCODING_VERSION,
        ethers.utils.defaultAbiCoder.encode(["uint256"], [_peer.chainId]),
      ]),
    },
    { value: mintValue, gasLimit: DEFAULT_TX_GAS_LIMIT }
  );
  await relayPriorityRequestsToChain(await tx.wait(), _chain.diamondProxy, _chain.provider);

  const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), _chain.provider);
  if ((await l2Bridgehub.baseTokenAssetId(_peer.chainId)) !== (await bridgehub.baseTokenAssetId(_peer.chainId))) {
    throw new Error(`Chain ${_chain.chainId} did not register chain ${_peer.chainId} before the upgrade`);
  }
  console.log(`   ✅ Chain ${_chain.chainId}: chain ${_peer.chainId} registered the legacy way`);
}

/**
 * After the upgrade: takes `_chain`, which registered `_peer` with {registerLegacyInteropPair}, and `_peer` through
 * {protocol-docs/interop-gating.md#order-per-chain}. The legacy pair stops sending, governance clears it, and once
 * both chains are enabled, each admin's consent opens its own direction.
 */
export async function runInteropGatingProcedure(
  _context: InteropGatingContext,
  _chain: GatedChain,
  _peer: GatedChain
): Promise<void> {
  await expectSendReverts(_chain, _peer, "DestinationChainNotAllowed(uint256)", "send over the legacy pair");
  await deregisterInteropPair(_context, _chain, _peer);
  await expectSendReverts(_chain, _peer, "DestinationChainNotRegistered(uint256)", "send over the cleared pair");

  await enableInterop(_context, _chain);
  await enableInterop(_context, _peer);

  await allowInteropPeer(_context, _chain, _peer);
  await expectSend(_chain, _peer);
  await expectSendReverts(_peer, _chain, "DestinationChainNotRegistered(uint256)", "send before the peer allows back");
  await allowInteropPeer(_context, _peer, _chain);
  await expectSend(_peer, _chain);
}

async function deregisterInteropPair(
  _context: InteropGatingContext,
  _chain: GatedChain,
  _peer: GatedChain
): Promise<void> {
  const sender = new ethers.Contract(
    _context.l1Addresses.chainRegistrationSender,
    getAbi("ChainRegistrationSender"),
    _context.l1Provider
  );
  const receipt = await asOwnerOf(_context, sender, (signer) =>
    sender.connect(signer).deregisterInteropPairs([_chain.chainId], [_peer.chainId])
  );
  await relayPriorityRequestsToChain(receipt, _chain.diamondProxy, _chain.provider);

  const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), _chain.provider);
  if ((await l2Bridgehub.baseTokenAssetId(_peer.chainId)) !== ethers.constants.HashZero) {
    throw new Error(`Chain ${_peer.chainId} is still registered on the L2Bridgehub of chain ${_chain.chainId}`);
  }
  console.log(`   ✅ Chain ${_chain.chainId}: legacy pair with chain ${_peer.chainId} cleared`);
}

async function enableInterop(_context: InteropGatingContext, _chain: GatedChain): Promise<void> {
  const { l1Addresses, l1Provider } = _context;
  const ntv = new ethers.Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
  const l1Bridgehub = new ethers.Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Provider);
  const messageRoot = new ethers.Contract(l1Addresses.messageRoot, getAbi("L1MessageRoot"), l1Provider);
  const assetIds: string[] = [
    ...new Set<string>([await ntv.BASE_TOKEN_ASSET_ID(), await l1Bridgehub.baseTokenAssetId(_chain.chainId)]),
  ];

  // Governance computes the backfill offchain ({protocol-docs/interop-gating.md#backfill-amounts}). The test
  // withdraws none of the balance the chain had before the upgrade, so zero stands in for it.
  await asOwnerOf(_context, ntv, (signer) =>
    ntv.connect(signer).setChainBalanceBackfill(
      _chain.chainId,
      assetIds,
      assetIds.map(() => 0)
    )
  );
  // The default upgrade keeps the chain's single-proof verifier, so the chain can't lock a second proof system.
  // Governance enables it without the lock, as it may for a chain it trusts for reasons checked offchain
  // ({protocol-docs/interop-gating.md#enabling-interop}). `enableInterop` belongs to the Bridgehub owner.
  await asOwnerOf(_context, l1Bridgehub, (signer) => messageRoot.connect(signer).enableInterop(_chain.chainId, false));
  for (const assetId of assetIds) {
    await (await ntv.connect(_context.chainAdminOwner).moveChainBalanceToInteropPool(_chain.chainId, assetId)).wait();
  }

  if (!(await messageRoot.isInteropEnabled(_chain.chainId))) {
    throw new Error(`Chain ${_chain.chainId} is not enabled for interop`);
  }
  for (const assetId of assetIds) {
    if (!(await ntv.chainBalanceInInteropPool(_chain.chainId, assetId))) {
      throw new Error(`Chain ${_chain.chainId} balance of asset ${assetId} was not moved to the interop pool`);
    }
  }
  console.log(`   ✅ Chain ${_chain.chainId}: interop enabled, balances moved to the pool`);
}

async function allowInteropPeer(_context: InteropGatingContext, _chain: GatedChain, _peer: GatedChain): Promise<void> {
  const sender = new ethers.Contract(
    _context.l1Addresses.chainRegistrationSender,
    getAbi("ChainRegistrationSender"),
    _context.l1Provider
  );
  const receipt = await chainAdminMulticall(_context, _chain, sender.address, [
    sender.interface.encodeFunctionData("allowInteropPeer", [_chain.chainId, _peer.chainId]),
  ]);
  await relayPriorityRequestsToChain(receipt, _chain.diamondProxy, _chain.provider);

  const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), _chain.provider);
  if (
    !(await sender.interopPeerAllowed(_chain.chainId, _peer.chainId)) ||
    !(await l2Bridgehub.isPeerAllowed(_peer.chainId))
  ) {
    throw new Error(`Chain ${_chain.chainId} did not allow chain ${_peer.chainId} as an interop peer`);
  }
  console.log(`   ✅ Chain ${_chain.chainId}: chain ${_peer.chainId} allowed as interop peer`);
}

async function expectSend(_source: GatedChain, _destination: GatedChain): Promise<void> {
  await sendToChain(_source, _destination);
  console.log(`   ✅ Chain ${_source.chainId} sends interop to chain ${_destination.chainId}`);
}

async function expectSendReverts(
  _source: GatedChain,
  _destination: GatedChain,
  _errorSignature: string,
  _label: string
): Promise<void> {
  await expectRevert(
    () => sendToChain(_source, _destination),
    `${_label} (${_source.chainId} -> ${_destination.chainId})`,
    customError("InteropCenter", _errorSignature, [_destination.chainId]),
    _source.provider
  );
  console.log(`   ✅ Chain ${_source.chainId} can't send interop to chain ${_destination.chainId}: ${_label}`);
}

async function sendToChain(_source: GatedChain, _destination: GatedChain): Promise<void> {
  await sendInteropMessage({
    sourceProvider: _source.provider,
    recipient: encodeEvmChainAddress(getInteropSourceAddress(), _destination.chainId),
    payload: "0x",
    attributes: [],
    value: await getInteropProtocolFee(_source.provider),
  });
}

/** Sends `_calls` to `_target` through `_chain`'s `ChainAdminOwnable`. */
async function chainAdminMulticall(
  _context: InteropGatingContext,
  _chain: GatedChain,
  _target: string,
  _calls: string[]
): Promise<providers.TransactionReceipt> {
  const zkChain = new ethers.Contract(_chain.diamondProxy, getAbi("IZKChain"), _context.l1Provider);
  const chainAdmin = new ethers.Contract(
    await zkChain.getAdmin(),
    getAbi("ChainAdminOwnable"),
    _context.chainAdminOwner
  );
  const calls = _calls.map((data) => ({ target: _target, value: 0, data }));
  return (await chainAdmin.multicall(calls, true)).wait();
}

/** Sends the transaction `_send` builds from the owner of `_ownable`: governance, after the upgrade. */
async function asOwnerOf(
  _context: InteropGatingContext,
  _ownable: ethers.Contract,
  _send: (_signer: providers.JsonRpcSigner) => Promise<providers.TransactionResponse>
): Promise<providers.TransactionReceipt> {
  return impersonateAndRun(_context.l1Provider, await _ownable.owner(), async (signer) => (await _send(signer)).wait());
}
