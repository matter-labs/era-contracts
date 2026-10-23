/**
 * Settles batches of the anvil chains on L1 through the chain's own commit -> prove -> execute flow, so
 * the L1 state a live chain reaches by settling (its pending system upgrade batch executed, every
 * committed batch executed) is reached here the same way. The anvil chains have no sequencer or
 * prover, so each settled batch is empty (no L1 or L2 txs, state unchanged) and is proven with the
 * mock proof the fixture's testnet verifier accepts.
 */

import { BigNumber, ethers } from "ethers";
import type { BigNumberish } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import {
  COMMIT_BATCH_INFO_ZKSYNC_OS_TUPLE_TYPE,
  COMMIT_BATCH_INFO_ZKSYNC_OS_V5_TUPLE_TYPE,
  COMMIT_ENCODING_VERSION,
  COMMIT_ENCODING_VERSION_6_FIRST_MINOR,
  COMMIT_ENCODING_VERSION_V5,
  DECODED_EXECUTE_DATA_TUPLE_TYPE,
  EMPTY_STRING_KECCAK,
  EXECUTE_ENCODING_VERSION,
  GENESIS_BATCH_COMMITMENT,
  L2_DA_COMMITMENT_SCHEME_EMPTY_NO_DA,
  PROOF_ENCODING_VERSION,
  PUBLIC_INPUT_SHIFT,
  STORED_BATCH_INFO_TUPLE_TYPE,
  ZKSYNC_OS_MOCK_PROOF_MAGIC,
  ZKSYNC_OS_MOCK_VERIFICATION_TYPE,
} from "../core/const";
import { sendAndCheck } from "./upgrade-test-utils";

type ChainRef = { chainId: number; diamondProxy: string };

/** The CTM genesis parameters a chain's batch zero is built from (see `ChainTypeManager.storedBatchZero`). */
export type GenesisBatchParams = {
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: BigNumberish;
};

/** Mirrors `IExecutor.StoredBatchInfo`. */
type StoredBatchInfo = {
  batchNumber: BigNumber;
  batchHash: string;
  indexRepeatedStorageChanges: BigNumberish;
  numberOfLayer1Txs: BigNumberish;
  priorityOperationsHash: string;
  dependencyRootsRollingHash: string;
  l2LogsTreeRoot: string;
  timestamp: BigNumberish;
  commitment: string;
};

type ChainSettlement = {
  lastBatch: StoredBatchInfo;
  // The chain batch root of a batch without L2->L1 logs or interop: the genesis batch's
  // (`ChainBatchRootTree.genesisChainBatchRoot`). MessageRoot rejects a zero one.
  emptyBatchRoot: string;
};

function hashStoredBatch(batch: StoredBatchInfo): string {
  return ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([STORED_BATCH_INFO_TUPLE_TYPE], [batch]));
}

function encodeVersioned(version: number, types: string[], values: unknown[]): string {
  return ethers.utils.hexConcat([[version], ethers.utils.defaultAbiCoder.encode(types, values)]);
}

export class BatchSettler {
  private constructor(
    private readonly operator: ethers.Wallet,
    private readonly provider: ethers.providers.JsonRpcProvider,
    private readonly settlements: Map<string, ChainSettlement>
  ) {}

  /**
   * Prepares `chains` for settlement: checks that none has committed a batch, so batch zero (built
   * from `genesis` and checked against the stored hash) is the one to build on, and gives each a
   * Validium DA validator pair, which commit requires and the fixture chains lack.
   * @param operator The chains' admin, holding the committer, prover and executor roles on the CTM's ValidatorTimelock.
   * @param chains The chains to settle.
   * @param genesis The genesis parameters of the CTM release the chains were created from.
   */
  static async create(operator: ethers.Wallet, chains: ChainRef[], genesis: GenesisBatchParams): Promise<BatchSettler> {
    const provider = operator.provider as ethers.providers.JsonRpcProvider;
    const batchZero: StoredBatchInfo = {
      batchNumber: BigNumber.from(0),
      batchHash: genesis.genesisBatchHash,
      indexRepeatedStorageChanges: genesis.genesisIndexRepeatedStorageChanges,
      numberOfLayer1Txs: 0,
      priorityOperationsHash: EMPTY_STRING_KECCAK,
      dependencyRootsRollingHash: ethers.constants.HashZero,
      l2LogsTreeRoot: ethers.constants.HashZero,
      timestamp: 0,
      commitment: GENESIS_BATCH_COMMITMENT,
    };

    const daValidator = await new ethers.ContractFactory(
      getAbi("ValidiumL1DAValidator"),
      getCreationBytecode("ValidiumL1DAValidator"),
      operator
    ).deploy();
    await daValidator.deployed();

    const settlements = new Map<string, ChainSettlement>();
    for (const chain of chains) {
      const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const committed = await getters.getTotalBatchesCommitted();
      if (!committed.isZero()) {
        throw new Error(`Chain ${chain.chainId} has committed ${committed} batches; expected none`);
      }
      const storedBatchZeroHash: string = await getters.storedBatchHash(0);
      if (hashStoredBatch(batchZero) !== storedBatchZeroHash) {
        throw new Error(
          `Chain ${chain.chainId}: batch zero built from genesis batch hash ${genesis.genesisBatchHash} hashes to ` +
            `${hashStoredBatch(batchZero)}, but the chain stores ${storedBatchZeroHash}`
        );
      }

      const admin = new ethers.Contract(chain.diamondProxy, getAbi("AdminFacet"), operator);
      await sendAndCheck(
        provider,
        admin.setDAValidatorPair(daValidator.address, L2_DA_COMMITMENT_SCHEME_EMPTY_NO_DA),
        `chain ${chain.chainId} setDAValidatorPair`
      );
      settlements.set(chain.diamondProxy, { lastBatch: batchZero, emptyBatchRoot: await getters.l2LogsRootHash(0) });
    }
    return new BatchSettler(operator, provider, settlements);
  }

  /**
   * Commits, proves and executes one empty batch on each of `chains` through the CTM's
   * ValidatorTimelock. A pending system upgrade tx goes into that batch, so its hash is cleared.
   * @param chains The chains to settle, each passed to `create`.
   */
  async settleNextBatch(chains: ChainRef[]): Promise<void> {
    for (const chain of chains) {
      await this.settleChainBatch(chain);
    }
  }

  private async settleChainBatch(chain: ChainRef): Promise<void> {
    const settlement = this.settlements.get(chain.diamondProxy);
    if (!settlement) {
      throw new Error(`Chain ${chain.chainId} was not prepared for settlement`);
    }
    const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), this.provider);
    const ctm = new ethers.Contract(await getters.getChainTypeManager(), getAbi("IChainTypeManager"), this.provider);
    const timelock = new ethers.Contract(
      await ctm.validatorTimelockPostV29(),
      getAbi("ValidatorTimelock"),
      this.operator
    );
    const prevBatch = settlement.lastBatch;
    const batchNumber = prevBatch.batchNumber.add(1);
    const label = `chain ${chain.chainId} batch ${batchNumber}`;

    // ── Commit ──
    const [, minor] = await getters.getSemverProtocolVersion();
    const hasInteropFeeUnits = minor >= COMMIT_ENCODING_VERSION_6_FIRST_MINOR;
    const { timestamp } = await this.provider.getBlock("latest");
    const newBatch = {
      batchNumber,
      newStateCommitment: prevBatch.batchHash,
      numberOfLayer1Txs: 0,
      numberOfLayer2Txs: 0,
      priorityOperationsHash: EMPTY_STRING_KECCAK,
      dependencyRootsRollingHash: ethers.constants.HashZero,
      l2LogsTreeRoot: settlement.emptyBatchRoot,
      daCommitmentScheme: L2_DA_COMMITMENT_SCHEME_EMPTY_NO_DA,
      daCommitment: ethers.constants.HashZero,
      firstBlockTimestamp: timestamp,
      firstBlockNumber: batchNumber,
      lastBlockTimestamp: timestamp,
      lastBlockNumber: batchNumber,
      chainId: chain.chainId,
      // ValidiumL1DAValidator takes the batch's state diff hash, which it does not check.
      operatorDAInput: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.constants.HashZero]),
      slChainId: (await this.provider.getNetwork()).chainId,
      chainConfigHash: await getters.getZKsyncOSChainConfigHash(),
      ...(hasInteropFeeUnits ? { interopFeeUnits: 0 } : {}),
    };
    const commitData = encodeVersioned(
      hasInteropFeeUnits ? COMMIT_ENCODING_VERSION : COMMIT_ENCODING_VERSION_V5,
      [
        STORED_BATCH_INFO_TUPLE_TYPE,
        `${hasInteropFeeUnits ? COMMIT_BATCH_INFO_ZKSYNC_OS_TUPLE_TYPE : COMMIT_BATCH_INFO_ZKSYNC_OS_V5_TUPLE_TYPE}[]`,
      ],
      [prevBatch, [newBatch]]
    );
    const commitReceipt = await sendAndCheck(
      this.provider,
      timelock.commitBatchesSharedBridge(chain.diamondProxy, batchNumber, batchNumber, commitData),
      `${label} commit`
    );
    const committer = new ethers.utils.Interface(getAbi("CommitterFacet"));
    const blockCommit = commitReceipt.logs
      .filter((log) => log.address.toLowerCase() === chain.diamondProxy.toLowerCase())
      .filter((log) => log.topics[0] === committer.getEventTopic("BlockCommit"))
      .map((log) => committer.parseLog(log));
    if (blockCommit.length !== 1) {
      throw new Error(`${label}: expected one BlockCommit event, got ${blockCommit.length}`);
    }
    const storedBatch: StoredBatchInfo = {
      batchNumber,
      batchHash: newBatch.newStateCommitment,
      indexRepeatedStorageChanges: 0,
      numberOfLayer1Txs: 0,
      priorityOperationsHash: newBatch.priorityOperationsHash,
      dependencyRootsRollingHash: newBatch.dependencyRootsRollingHash,
      l2LogsTreeRoot: newBatch.l2LogsTreeRoot,
      timestamp: 0,
      commitment: blockCommit[0].args.commitment,
    };
    const storedBatchHash: string = await getters.storedBatchHash(batchNumber);
    if (hashStoredBatch(storedBatch) !== storedBatchHash) {
      throw new Error(
        `${label}: rebuilt stored batch hashes to ${hashStoredBatch(storedBatch)}, chain stores ${storedBatchHash}`
      );
    }

    // ── Prove ──
    // Computed here rather than by the chain's verifier: `MultiProofTestnetVerifier` (v0.35 chain states) has no
    // `computeZKsyncOSHash`. Both testnet verifiers expect a single batch's commitment shifted by PUBLIC_INPUT_SHIFT.
    const proof = [
      ZKSYNC_OS_MOCK_VERIFICATION_TYPE,
      0, // no previous proof hash to chain onto
      ZKSYNC_OS_MOCK_PROOF_MAGIC,
      BigNumber.from(storedBatch.commitment).shr(PUBLIC_INPUT_SHIFT),
    ];
    const proofData = encodeVersioned(
      PROOF_ENCODING_VERSION,
      [STORED_BATCH_INFO_TUPLE_TYPE, `${STORED_BATCH_INFO_TUPLE_TYPE}[]`, "uint256[]"],
      [prevBatch, [storedBatch], proof]
    );
    await sendAndCheck(
      this.provider,
      timelock.proveBatchesSharedBridge(chain.diamondProxy, batchNumber, batchNumber, proofData),
      `${label} prove`
    );

    // ── Execute ──
    const executeData = encodeVersioned(
      EXECUTE_ENCODING_VERSION,
      [DECODED_EXECUTE_DATA_TUPLE_TYPE],
      [
        {
          batchesData: [storedBatch],
          priorityOpsData: [{ leftPath: [], rightPath: [], itemHashes: [] }],
          dependencyRoots: [[]],
        },
      ]
    );
    await sendAndCheck(
      this.provider,
      timelock.executeBatchesSharedBridge(chain.diamondProxy, batchNumber, batchNumber, executeData),
      `${label} execute`
    );

    const executed: BigNumber = await getters.getTotalBatchesExecuted();
    if (!executed.eq(batchNumber)) {
      throw new Error(`${label}: chain reports ${executed} executed batches`);
    }
    const upgradeTxHash: string = await getters.getL2SystemContractsUpgradeTxHash();
    if (upgradeTxHash !== ethers.constants.HashZero) {
      throw new Error(`${label}: system upgrade tx ${upgradeTxHash} still pending after execution`);
    }
    settlement.lastBatch = storedBatch;
    console.log(`   ${label} committed, proven and executed`);
  }
}
