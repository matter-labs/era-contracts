import type { BigNumber, providers } from "ethers";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
  ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  DEFAULT_TX_GAS_LIMIT,
  L2_BRIDGEHUB_ADDR,
  LEGACY_CHAIN_REGISTRATION_ENCODING_VERSION,
  PRE_UPGRADE_DEPOSIT_MAX_ETH,
  PRE_UPGRADE_DEPOSIT_MIN_ETH,
} from "../core/const";
import { getInteropSourceAddress } from "../core/accounts";
import { decodeBridgeBurnAmount, encodeBridgeMintData } from "../core/data-encoding";
import type { CoreDeployedAddresses } from "../core/types";
import { impersonateAndRun, relayPriorityRequestsToChain } from "../core/utils";
import { customError, expectRevert, randomBigNumber } from "./balance-helpers";
import { encodeEvmChainAddress } from "./erc7930";
import { getInteropProtocolFee, sendInteropMessage } from "./interop-helpers";
import { depositETHToL2 } from "./l1-deposit-helper";

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

/** Before the upgrade: deposits a random amount of ether to `_chain`, a balance governance backfills afterwards. */
export async function depositBeforeUpgrade(_context: InteropGatingContext, _chain: GatedChain): Promise<void> {
  await depositETHToL2({
    l1RpcUrl: _context.l1Provider.connection.url,
    l2RpcUrl: _chain.provider.connection.url,
    chainId: _chain.chainId,
    l1Addresses: _context.l1Addresses,
    amount: randomBigNumber(
      ethers.utils.parseEther(PRE_UPGRADE_DEPOSIT_MIN_ETH),
      ethers.utils.parseEther(PRE_UPGRADE_DEPOSIT_MAX_ETH)
    ),
  });
}

/**
 * After the upgrade: takes `_chain`, which registered `_peer` with {registerLegacyInteropPair}, and `_peer` through
 * {protocol-docs/interop-gating.md#order-per-chain}. The legacy pair stops sending, governance clears it, and once
 * both chains are enabled, each admin's consent opens its own direction.
 * @param _lastPreUpgradeBlock The last L1 block before the core upgrade, up to which the backfill is computed.
 */
export async function runInteropGatingProcedure(
  _context: InteropGatingContext,
  _lastPreUpgradeBlock: number,
  _chain: GatedChain,
  _peer: GatedChain
): Promise<void> {
  await expectSendReverts(_chain, _peer, "DestinationChainNotAllowed(uint256)", "send over the legacy pair");
  await deregisterInteropPair(_context, _chain, _peer);
  await expectSendReverts(_chain, _peer, "DestinationChainNotRegistered(uint256)", "send over the cleared pair");

  await enableInterop(_context, _chain, _lastPreUpgradeBlock);
  await enableInterop(_context, _peer, _lastPreUpgradeBlock);

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

async function enableInterop(
  _context: InteropGatingContext,
  _chain: GatedChain,
  _lastPreUpgradeBlock: number
): Promise<void> {
  const { l1Addresses, l1Provider } = _context;
  const ntv = new ethers.Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
  const l1Bridgehub = new ethers.Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Provider);
  const messageRoot = new ethers.Contract(l1Addresses.messageRoot, getAbi("L1MessageRoot"), l1Provider);
  const assetIds: string[] = [
    ...new Set<string>([await ntv.BASE_TOKEN_ASSET_ID(), await l1Bridgehub.baseTokenAssetId(_chain.chainId)]),
  ];
  const backfills: BigNumber[] = [];
  for (const assetId of assetIds) {
    const backfill = await preUpgradeBalance(_context, _chain.chainId, assetId, _lastPreUpgradeBlock);
    if (backfill.lte(0)) {
      throw new Error(`Chain ${_chain.chainId} held no asset ${assetId} before the upgrade`);
    }
    await expectRevert(
      () => simulateWithdrawal(_context, ntv, _chain.chainId, assetId, backfill),
      `withdraw the pre-upgrade balance of chain ${_chain.chainId} before the backfill`,
      customError("L1NativeTokenVault", "ChainBalanceExceeded(uint256,bytes32,uint256,uint256)", [
        _chain.chainId,
        assetId,
        (await ntv.chainTotalWithdrawn(_chain.chainId, assetId)).add(backfill),
        await ntv.chainTotalDeposited(_chain.chainId, assetId),
      ]),
      l1Provider
    );
    backfills.push(backfill);
  }

  await asOwnerOf(_context, ntv, (signer) =>
    ntv.connect(signer).setChainBalanceBackfill(_chain.chainId, assetIds, backfills)
  );
  for (const [i, assetId] of assetIds.entries()) {
    const { amount, set } = await ntv.chainBalanceBackfill(_chain.chainId, assetId);
    if (!set || !amount.eq(backfills[i])) {
      throw new Error(`Chain ${_chain.chainId} backfill of asset ${assetId} is ${amount} (set: ${set})`);
    }
  }
  // The default upgrade keeps the chain's single-proof verifier, so the chain can't lock a second proof system.
  // Governance enables it without the lock, as it may for a chain it trusts for reasons checked offchain
  // ({protocol-docs/interop-gating.md#enabling-interop}). `enableInterop` belongs to the Bridgehub owner.
  await asOwnerOf(_context, l1Bridgehub, (signer) => messageRoot.connect(signer).enableInterop(_chain.chainId, false));
  for (const [i, assetId] of assetIds.entries()) {
    const deposited = await ntv.chainTotalDeposited(_chain.chainId, assetId);
    const withdrawn = await ntv.chainTotalWithdrawn(_chain.chainId, assetId);
    const poolDepositedBefore = await ntv.interopPoolTotalDeposited(assetId);
    const poolWithdrawnBefore = await ntv.interopPoolTotalWithdrawn(assetId);
    await (await ntv.connect(_context.chainAdminOwner).moveChainBalanceToInteropPool(_chain.chainId, assetId)).wait();
    const poolDepositedDelta = (await ntv.interopPoolTotalDeposited(assetId)).sub(poolDepositedBefore);
    const poolWithdrawnDelta = (await ntv.interopPoolTotalWithdrawn(assetId)).sub(poolWithdrawnBefore);
    if (
      !(await ntv.chainBalanceInInteropPool(_chain.chainId, assetId)) ||
      !poolDepositedDelta.eq(deposited.add(backfills[i])) ||
      !poolWithdrawnDelta.eq(withdrawn)
    ) {
      throw new Error(
        `Chain ${_chain.chainId} balance of asset ${assetId} was not moved to the interop pool: ` +
          `pool deposits +${poolDepositedDelta}, expected +${deposited.add(backfills[i])}; ` +
          `pool withdrawals +${poolWithdrawnDelta}, expected +${withdrawn}`
      );
    }
    await simulateWithdrawal(_context, ntv, _chain.chainId, assetId, backfills[i]);
  }

  if (!(await messageRoot.isInteropEnabled(_chain.chainId))) {
    throw new Error(`Chain ${_chain.chainId} is not enabled for interop`);
  }
  console.log(`   ✅ Chain ${_chain.chainId}: interop enabled, backfilled balances moved to the pool and withdrawable`);
}

/**
 * Returns what `_chainId` held of `_assetId` at `_toBlock`: its deposits less its finalized withdrawals and claimed
 * failed deposits, as governance computes the backfill ({protocol-docs/interop-gating.md#backfill-amounts}).
 * Governance reads the whole history. The chain states the test starts from keep no logs, so the flows they were
 * built with are left out, which only under-credits the chain.
 */
async function preUpgradeBalance(
  _context: InteropGatingContext,
  _chainId: number,
  _assetId: string,
  _toBlock: number
): Promise<BigNumber> {
  const { l1Addresses, l1Provider } = _context;
  const ntv = new ethers.Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
  const assetRouter = new ethers.Contract(l1Addresses.l1SharedBridge, getAbi("L1AssetRouter"), l1Provider);
  const total = async (
    _contract: ethers.Contract,
    _event: string,
    _amount: (_args: ethers.utils.Result) => BigNumber
  ) =>
    (await _contract.queryFilter(_contract.filters[_event](_chainId, _assetId), 0, _toBlock)).reduce(
      (_sum, _log) => _sum.add(_amount(_log.args!)),
      ethers.constants.Zero
    );
  const deposited = await total(ntv, "BridgeBurn", (_args) => _args.amount);
  const withdrawn = await total(ntv, "BridgeMint", (_args) => _args.amount);
  // L1NativeTokenVault emits nothing for a claimed failed deposit; the asset router logs the deposit's burn data.
  const failedDepositsClaimed = await total(assetRouter, "ClaimedFailedDepositAssetRouter", (_args) =>
    decodeBridgeBurnAmount(_args.assetData)
  );
  return deposited.sub(withdrawn).sub(failedDepositsClaimed);
}

/**
 * Simulates L1AssetRouter finalizing a withdrawal of `_amount` of `_assetId` from `_chainId`, which the cap allows
 * or not. The upgrade installs the real L1MessageRoot, which the harness's mock proofs can't finalize against.
 */
async function simulateWithdrawal(
  _context: InteropGatingContext,
  _ntv: ethers.Contract,
  _chainId: number,
  _assetId: string,
  _amount: BigNumber
): Promise<void> {
  const receiver = _context.chainAdminOwner.address;
  await _ntv.callStatic.bridgeMint(
    _chainId,
    _assetId,
    encodeBridgeMintData(receiver, receiver, await _ntv.tokenAddress(_assetId), _amount, "0x"),
    { from: _context.l1Addresses.l1SharedBridge }
  );
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
