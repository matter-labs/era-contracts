import { expect } from "chai";
import type { BigNumberish } from "ethers";
import { Wallet } from "ethers";
import * as ethers from "ethers";
import * as hardhat from "hardhat";
import { hashBytecode } from "zksync-ethers/build/utils";

import type { AdminFacet, ExecutorFacet, GettersFacet, StateTransitionManager } from "../../typechain";
import {
  AdminFacetFactory,
  DummyAdminFacetFactory,
  CustomUpgradeTestFactory,
  DefaultUpgradeFactory,
  ExecutorFacetFactory,
  GettersFacetFactory,
  StateTransitionManagerFactory,
} from "../../typechain";

import { Ownable2StepFactory } from "../../typechain/Ownable2StepFactory";

import { L2_BOOTLOADER_BYTECODE_HASH, L2_DEFAULT_ACCOUNT_BYTECODE_HASH } from "../../src.ts/deploy-process";
import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";

import type { ProposedUpgrade, VerifierParams } from "../../src.ts/utils";
import { ethTestConfig, EMPTY_STRING_KECCAK } from "../../src.ts/utils";
import { diamondCut, Action, facetCut } from "../../src.ts/diamondCut";

import type { CommitBatchInfo, StoredBatchInfo, CommitBatchInfoWithTimestamp } from "./utils";
import {
  L2_BOOTLOADER_ADDRESS,
  L2_SYSTEM_CONTEXT_ADDRESS,
  SYSTEM_LOG_KEYS,
  constructL2Log,
  createSystemLogs,
  genesisStoredBatchInfo,
  getCallRevertReason,
  packBatchTimestampAndBatchTimestamp,
  buildL2CanonicalTransaction,
  buildCommitBatchInfoWithUpgrade,
  makeExecutedEqualCommitted,
  getBatchStoredInfo,
} from "./utils";
import { packSemver, unpackStringSemVer, addToProtocolVersion } from "../../scripts/utils";

describe.only("L2 upgrade test", function () {
  let proxyExecutor: ExecutorFacet;
  let proxyAdmin: AdminFacet;
  let proxyGetters: GettersFacet;

  let stateTransitionManager: StateTransitionManager;

  let owner: ethers.Signer;

  let batch1InfoChainIdUpgrade: CommitBatchInfo;
  let storedBatch1InfoChainIdUpgrade: StoredBatchInfo;

  let batch2Info: CommitBatchInfo;
  let storedBatch2Info: StoredBatchInfo;

  let verifier: string;
  const noopUpgradeTransaction = buildL2CanonicalTransaction({ txType: 0 });
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;
  let initialProtocolVersion = 0;
  let initialMinorProtocolVersion = 0;

  before(async () => {
    [owner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    const gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    const dummyAdminFacetFactory = await hardhat.ethers.getContractFactory("DummyAdminFacet");
    const dummyAdminFacetContract = await dummyAdminFacetFactory.deploy();
    const extraFacet = facetCut(dummyAdminFacetContract.address, dummyAdminFacetContract.interface, Action.Add, true);

    const deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [extraFacet]);
    const ownable = Ownable2StepFactory.connect(deployer.addresses.StateTransition.StateTransitionProxy, deployWallet);
    const data = ownable.interface.encodeFunctionData("transferOwnership", [deployWallet.address]);
    await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, data);
    const transferOwnershipTx = await ownable.acceptOwnership();
    await transferOwnershipTx.wait();

    const [initialMajor, initialMinor, initialPatch] = unpackStringSemVer(
      process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION
    );
    if (initialMajor !== 0 || initialPatch !== 0) {
      throw new Error("Initial protocol version must be 0.x.0");
    }
    initialProtocolVersion = packSemver(initialMajor, initialMinor, initialPatch);
    initialMinorProtocolVersion = initialMinor;

    chainId = deployer.chainId;
    verifier = deployer.addresses.StateTransition.Verifier;

    proxyExecutor = ExecutorFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    proxyGetters = GettersFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    proxyAdmin = AdminFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    const dummyAdminFacet = DummyAdminFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
      deployWallet
    );

    stateTransitionManager = StateTransitionManagerFactory.connect(
      deployer.addresses.StateTransition.StateTransitionProxy,
      deployWallet
    );

    await (await dummyAdminFacet.dummySetValidator(await deployWallet.getAddress())).wait();

    // do initial setChainIdUpgrade
    const upgradeTxHash = await proxyGetters.getL2SystemContractsUpgradeTxHash();
    batch1InfoChainIdUpgrade = await buildCommitBatchInfoWithUpgrade(
      genesisStoredBatchInfo(),
      {
        batchNumber: 1,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        numberOfLayer1Txs: "0x0000000000000000000000000000000000000000000000000000000000000000",
      },
      upgradeTxHash
    );

    const commitReceipt = await (
      await proxyExecutor.commitBatches(genesisStoredBatchInfo(), [batch1InfoChainIdUpgrade])
    ).wait();
    const commitment = commitReceipt.events[0].args.commitment;
    storedBatch1InfoChainIdUpgrade = getBatchStoredInfo(batch1InfoChainIdUpgrade, commitment);
    await makeExecutedEqualCommitted(proxyExecutor, genesisStoredBatchInfo(), [storedBatch1InfoChainIdUpgrade], []);
  });

  it("Upgrade should work even if not all batches are processed", async () => {
    batch2Info = await buildCommitBatchInfo(storedBatch1InfoChainIdUpgrade, {
      batchNumber: 2,
      priorityOperationsHash: EMPTY_STRING_KECCAK,
      numberOfLayer1Txs: "0x0000000000000000000000000000000000000000000000000000000000000000",
    });

    const commitReceipt = await (
      await proxyExecutor.commitBatches(storedBatch1InfoChainIdUpgrade, [batch2Info])
    ).wait();
    const commitment = commitReceipt.events[0].args.commitment;

    expect(await proxyGetters.getProtocolVersion()).to.equal(initialProtocolVersion);
    expect(await proxyGetters.getL2SystemContractsUpgradeTxHash()).to.equal(ethers.constants.HashZero);

    await (
      await executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 1, 0),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    ).wait();

    expect(await proxyGetters.getProtocolVersion()).to.equal(addToProtocolVersion(initialProtocolVersion, 1, 0));

    storedBatch2Info = getBatchStoredInfo(batch2Info, commitment);

    await makeExecutedEqualCommitted(proxyExecutor, storedBatch1InfoChainIdUpgrade, [storedBatch2Info], []);
  });

  it("Should not allow base system contract changes during patch upgrade", async () => {
    const { 0: major, 1: minor, 2: patch } = await proxyGetters.getSemverProtocolVersion();

    const bootloaderRevertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: packSemver(major, minor, patch + 1),
        bootloaderHash: ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32))),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    );
    expect(bootloaderRevertReason).to.equal("Patch only upgrade can not set new bootloader");

    const defaultAccountRevertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: packSemver(major, minor, patch + 1),
        defaultAccountHash: ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32))),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    );
    expect(defaultAccountRevertReason).to.equal("Patch only upgrade can not set new default account");
  });

  it("Should not allow upgrade transaction during patch upgrade", async () => {
    const { 0: major, 1: minor, 2: patch } = await proxyGetters.getSemverProtocolVersion();

    const someTx = buildL2CanonicalTransaction({
      txType: 254,
      nonce: 0,
    });

    const bootloaderRevertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: packSemver(major, minor, patch + 1),
        l2ProtocolUpgradeTx: someTx,
      })
    );
    expect(bootloaderRevertReason).to.equal("Patch only upgrade can not set upgrade transaction");
  });

  it("Should not allow major version change", async () => {
    // 2**64 is the offset for a major version change
    const newVersion = ethers.BigNumber.from(2).pow(64);

    const someTx = buildL2CanonicalTransaction({
      txType: 254,
      nonce: 0,
    });

    const bootloaderRevertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: newVersion,
        l2ProtocolUpgradeTx: someTx,
      })
    );
    expect(bootloaderRevertReason).to.equal("Major must always be 0");
  });

  it("Timestamp should behave correctly", async () => {
    // Upgrade was scheduled for now should work fine
    const timeNow = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    await executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
      upgradeTimestamp: ethers.BigNumber.from(timeNow),
      l2ProtocolUpgradeTx: noopUpgradeTransaction,
    });

    // Upgrade that was scheduled for the future should not work now
    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        upgradeTimestamp: ethers.BigNumber.from(timeNow).mul(2),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    );
    expect(revertReason).to.equal("Upgrade is not ready yet");
  });

  it("Should require correct tx type for upgrade tx", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      txType: 255,
    });
    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 3, 0),
      })
    );

    expect(revertReason).to.equal("L2 system upgrade tx type is wrong");
  });

  it("Should include the new protocol version as part of nonce", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      txType: 254,
      nonce: 0,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("The new protocol version should be included in the L2 system upgrade tx");
  });

  it("Should ensure monotonic protocol version", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      txType: 254,
      nonce: 0,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: 0,
      })
    );

    expect(revertReason).to.equal("New protocol version is not greater than the current one");
  });

  it("Should ensure protocol version not increasing too much", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      txType: 254,
      nonce: 0,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 10000, 0),
      })
    );

    expect(revertReason).to.equal("Too big protocol version difference");
  });

  it("Should validate upgrade transaction overhead", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      nonce: 0,
      gasLimit: 0,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("my");
  });

  it("Should validate upgrade transaction gas max", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      nonce: 0,
      gasLimit: 1000000000000,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("ui");
  });

  it("Should validate upgrade transaction cannot output more pubdata than processable", async () => {
    const wrongTx = buildL2CanonicalTransaction({
      nonce: 0,
      gasLimit: 10000000,
      gasPerPubdataByteLimit: 1,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("uk");
  });

  it("Should validate factory deps", async () => {
    const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const wrongFactoryDepHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
    const wrongTx = buildL2CanonicalTransaction({
      factoryDeps: [wrongFactoryDepHash],
      nonce: 4 + initialMinorProtocolVersion,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        factoryDeps: [myFactoryDep],
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("Wrong factory dep hash");
  });

  it("Should validate factory deps length match", async () => {
    const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const wrongTx = buildL2CanonicalTransaction({
      factoryDeps: [],
      nonce: 4 + initialMinorProtocolVersion,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        factoryDeps: [myFactoryDep],
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("Wrong number of factory deps");
  });

  it("Should validate factory deps length isn't too large", async () => {
    const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const randomDepHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));

    const wrongTx = buildL2CanonicalTransaction({
      factoryDeps: Array(33).fill(randomDepHash),
      nonce: 4 + initialMinorProtocolVersion,
    });

    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        l2ProtocolUpgradeTx: wrongTx,
        factoryDeps: Array(33).fill(myFactoryDep),
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 4, 0),
      })
    );

    expect(revertReason).to.equal("Factory deps can be at most 32");
  });

  let l2UpgradeTxHash: string;
  it("Should successfully perform an upgrade", async () => {
    const bootloaderHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
    const defaultAccountHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
    const testnetVerifierFactory = await hardhat.ethers.getContractFactory("TestnetVerifier");
    const testnetVerifierContract = await testnetVerifierFactory.deploy();
    const newVerifier = testnetVerifierContract.address;
    const newerVerifierParams = buildVerifierParams({
      recursionNodeLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionLeafLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionCircuitsSetVksHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    });

    const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const myFactoryDepHash = hashBytecode(myFactoryDep);
    const upgradeTx = buildL2CanonicalTransaction({
      factoryDeps: [myFactoryDepHash],
      nonce: 5 + initialMinorProtocolVersion,
    });

    const upgrade = {
      bootloaderHash,
      defaultAccountHash,
      verifier: newVerifier,
      verifierParams: newerVerifierParams,
      executeUpgradeTx: true,
      l2ProtocolUpgradeTx: upgradeTx,
      factoryDeps: [myFactoryDep],
      newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 5, 0),
    };

    const upgradeReceipt = await (
      await executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, upgrade)
    ).wait();

    const defaultUpgradeFactory = await hardhat.ethers.getContractFactory("DefaultUpgrade");
    const upgradeEvents = upgradeReceipt.logs.map((log) => {
      // Not all events can be parsed there, but we don't care about them
      try {
        const event = defaultUpgradeFactory.interface.parseLog(log);
        const parsedArgs = event.args;
        return {
          name: event.name,
          args: parsedArgs,
        };
      } catch (_) {
        // lint no-empty
      }
    });
    l2UpgradeTxHash = upgradeEvents.find((event) => event.name == "UpgradeComplete").args.l2UpgradeTxHash;

    // Now, we check that all the data was set as expected
    expect(await proxyGetters.getL2BootloaderBytecodeHash()).to.equal(bootloaderHash);
    expect(await proxyGetters.getL2DefaultAccountBytecodeHash()).to.equal(defaultAccountHash);
    expect((await proxyGetters.getVerifier()).toLowerCase()).to.equal(newVerifier.toLowerCase());
    expect(await proxyGetters.getProtocolVersion()).to.equal(addToProtocolVersion(initialProtocolVersion, 5, 0));

    const newVerifierParams = await proxyGetters.getVerifierParams();
    expect(newVerifierParams.recursionNodeLevelVkHash).to.equal(newerVerifierParams.recursionNodeLevelVkHash);
    expect(newVerifierParams.recursionLeafLevelVkHash).to.equal(newerVerifierParams.recursionLeafLevelVkHash);
    expect(newVerifierParams.recursionCircuitsSetVksHash).to.equal(newerVerifierParams.recursionCircuitsSetVksHash);

    expect(upgradeEvents[0].name).to.eq("NewProtocolVersion");
    expect(upgradeEvents[0].args.previousProtocolVersion.toString()).to.eq(
      addToProtocolVersion(initialProtocolVersion, 2, 0).toString()
    );
    expect(upgradeEvents[0].args.newProtocolVersion.toString()).to.eq(
      addToProtocolVersion(initialProtocolVersion, 5, 0).toString()
    );

    expect(upgradeEvents[1].name).to.eq("NewVerifier");
    expect(upgradeEvents[1].args.oldVerifier.toLowerCase()).to.eq(verifier.toLowerCase());
    expect(upgradeEvents[1].args.newVerifier.toLowerCase()).to.eq(newVerifier.toLowerCase());

    expect(upgradeEvents[2].name).to.eq("NewVerifierParams");
    expect(upgradeEvents[2].args.oldVerifierParams[0]).to.eq(ethers.constants.HashZero);
    expect(upgradeEvents[2].args.oldVerifierParams[1]).to.eq(ethers.constants.HashZero);
    expect(upgradeEvents[2].args.oldVerifierParams[2]).to.eq(ethers.constants.HashZero);
    expect(upgradeEvents[2].args.newVerifierParams[0]).to.eq(newerVerifierParams.recursionNodeLevelVkHash);
    expect(upgradeEvents[2].args.newVerifierParams[1]).to.eq(newerVerifierParams.recursionLeafLevelVkHash);
    expect(upgradeEvents[2].args.newVerifierParams[2]).to.eq(newerVerifierParams.recursionCircuitsSetVksHash);

    expect(upgradeEvents[3].name).to.eq("NewL2BootloaderBytecodeHash");
    expect(upgradeEvents[3].args.previousBytecodeHash).to.eq(L2_BOOTLOADER_BYTECODE_HASH);
    expect(upgradeEvents[3].args.newBytecodeHash).to.eq(bootloaderHash);

    expect(upgradeEvents[4].name).to.eq("NewL2DefaultAccountBytecodeHash");
    expect(upgradeEvents[4].args.previousBytecodeHash).to.eq(L2_DEFAULT_ACCOUNT_BYTECODE_HASH);
    expect(upgradeEvents[4].args.newBytecodeHash).to.eq(defaultAccountHash);
  });

  it("Should successfully perform a patch upgrade even if there is a pending minor upgrade", async () => {
    const currentVerifier = await proxyGetters.getVerifier();
    const currentVerifierParams = await proxyGetters.getVerifierParams();
    const currentBootloaderHash = await proxyGetters.getL2BootloaderBytecodeHash();
    const currentL2DefaultAccountBytecodeHash = await proxyGetters.getL2DefaultAccountBytecodeHash();

    const testnetVerifierFactory = await hardhat.ethers.getContractFactory("TestnetVerifier");
    const testnetVerifierContract = await testnetVerifierFactory.deploy();
    const newVerifier = testnetVerifierContract.address;
    const newerVerifierParams = buildVerifierParams({
      recursionNodeLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionLeafLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionCircuitsSetVksHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    });

    const emptyTx = buildL2CanonicalTransaction({
      txType: 0,
      nonce: 0,
    });

    const upgrade = {
      verifier: newVerifier,
      verifierParams: newerVerifierParams,
      newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 5, 1),
      l2ProtocolUpgradeTx: emptyTx,
    };

    const upgradeReceipt = await (
      await executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, upgrade)
    ).wait();

    const defaultUpgradeFactory = await hardhat.ethers.getContractFactory("DefaultUpgrade");
    const upgradeEvents = upgradeReceipt.logs.map((log) => {
      // Not all events can be parsed there, but we don't care about them
      try {
        const event = defaultUpgradeFactory.interface.parseLog(log);
        const parsedArgs = event.args;
        return {
          name: event.name,
          args: parsedArgs,
        };
      } catch (_) {
        // lint no-empty
      }
    });

    // Now, we check that all the data was set as expected
    expect(await proxyGetters.getL2BootloaderBytecodeHash()).to.equal(currentBootloaderHash);
    expect(await proxyGetters.getL2DefaultAccountBytecodeHash()).to.equal(currentL2DefaultAccountBytecodeHash);
    expect((await proxyGetters.getVerifier()).toLowerCase()).to.equal(newVerifier.toLowerCase());
    expect(await proxyGetters.getProtocolVersion()).to.equal(addToProtocolVersion(initialProtocolVersion, 5, 1));

    const newVerifierParams = await proxyGetters.getVerifierParams();
    expect(newVerifierParams.recursionNodeLevelVkHash).to.equal(newerVerifierParams.recursionNodeLevelVkHash);
    expect(newVerifierParams.recursionLeafLevelVkHash).to.equal(newerVerifierParams.recursionLeafLevelVkHash);
    expect(newVerifierParams.recursionCircuitsSetVksHash).to.equal(newerVerifierParams.recursionCircuitsSetVksHash);

    expect(upgradeEvents[0].name).to.eq("NewProtocolVersion");
    expect(upgradeEvents[0].args.previousProtocolVersion.toString()).to.eq(
      addToProtocolVersion(initialProtocolVersion, 5, 0).toString()
    );
    expect(upgradeEvents[0].args.newProtocolVersion.toString()).to.eq(
      addToProtocolVersion(initialProtocolVersion, 5, 1).toString()
    );

    expect(upgradeEvents[1].name).to.eq("NewVerifier");
    expect(upgradeEvents[1].args.oldVerifier.toLowerCase()).to.eq(currentVerifier.toLowerCase());
    expect(upgradeEvents[1].args.newVerifier.toLowerCase()).to.eq(newVerifier.toLowerCase());

    expect(upgradeEvents[2].name).to.eq("NewVerifierParams");
    expect(upgradeEvents[2].args.oldVerifierParams[0]).to.eq(currentVerifierParams.recursionNodeLevelVkHash);
    expect(upgradeEvents[2].args.oldVerifierParams[1]).to.eq(currentVerifierParams.recursionLeafLevelVkHash);
    expect(upgradeEvents[2].args.oldVerifierParams[2]).to.eq(currentVerifierParams.recursionCircuitsSetVksHash);
    expect(upgradeEvents[2].args.newVerifierParams[0]).to.eq(newerVerifierParams.recursionNodeLevelVkHash);
    expect(upgradeEvents[2].args.newVerifierParams[1]).to.eq(newerVerifierParams.recursionLeafLevelVkHash);
    expect(upgradeEvents[2].args.newVerifierParams[2]).to.eq(newerVerifierParams.recursionCircuitsSetVksHash);
  });

  it("Should fail to upgrade when there is already a pending upgrade", async () => {
    const bootloaderHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
    const defaultAccountHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
    const verifier = ethers.utils.hexlify(ethers.utils.randomBytes(20));
    const verifierParams = buildVerifierParams({
      recursionNodeLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionLeafLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
      recursionCircuitsSetVksHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    });

    const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const myFactoryDepHash = hashBytecode(myFactoryDep);
    const upgradeTx = buildL2CanonicalTransaction({
      factoryDeps: [myFactoryDepHash],
      nonce: 5 + 1 + initialMinorProtocolVersion,
    });

    const upgrade = {
      bootloaderHash,
      defaultAccountHash,
      verifier: verifier,
      verifierParams,
      executeUpgradeTx: true,
      l2ProtocolUpgradeTx: upgradeTx,
      factoryDeps: [myFactoryDep],
      newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 5 + 1, 0),
    };
    const revertReason = await getCallRevertReason(
      executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, upgrade)
    );
    await rollBackToVersion(
      addToProtocolVersion(initialProtocolVersion, 5, 1).toString(),
      stateTransitionManager,
      upgrade
    );
    expect(revertReason).to.equal("Previous upgrade has not been finalized");
  });

  it("Should require that the next commit batches contains an upgrade tx", async () => {
    if (!l2UpgradeTxHash) {
      throw new Error("Can not perform this test without l2UpgradeTxHash");
    }

    const batch3InfoNoUpgradeTx = await buildCommitBatchInfo(storedBatch2Info, {
      batchNumber: 3,
    });
    const revertReason = await getCallRevertReason(
      proxyExecutor.commitBatches(storedBatch2Info, [batch3InfoNoUpgradeTx])
    );
    expect(revertReason).to.equal("b8");
  });

  it("Should ensure any additional upgrade logs go to the priority ops hash", async () => {
    if (!l2UpgradeTxHash) {
      throw new Error("Can not perform this test without l2UpgradeTxHash");
    }

    const systemLogs = createSystemLogs();
    systemLogs.push(
      constructL2Log(
        true,
        L2_BOOTLOADER_ADDRESS,
        SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
        l2UpgradeTxHash
      )
    );
    systemLogs.push(
      constructL2Log(
        true,
        L2_BOOTLOADER_ADDRESS,
        SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
        l2UpgradeTxHash
      )
    );
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch3InfoNoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 3,
      },
      systemLogs
    );
    const revertReason = await getCallRevertReason(
      proxyExecutor.commitBatches(storedBatch2Info, [batch3InfoNoUpgradeTx])
    );
    expect(revertReason).to.equal("kp");
  });

  it("Should fail to commit when upgrade tx hash does not match", async () => {
    const timestamp = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    const systemLogs = createSystemLogs();
    systemLogs.push(
      constructL2Log(
        true,
        L2_BOOTLOADER_ADDRESS,
        SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
        ethers.constants.HashZero
      )
    );
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch3InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 3,
        timestamp,
      },
      systemLogs
    );

    const revertReason = await getCallRevertReason(
      proxyExecutor.commitBatches(storedBatch2Info, [batch3InfoTwoUpgradeTx])
    );
    expect(revertReason).to.equal("ut");
  });

  it("Should commit successfully when the upgrade tx is present", async () => {
    const timestamp = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    const systemLogs = createSystemLogs();
    systemLogs.push(
      constructL2Log(
        true,
        L2_BOOTLOADER_ADDRESS,
        SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
        l2UpgradeTxHash
      )
    );
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch3InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 3,
        timestamp,
      },
      systemLogs
    );

    await (await proxyExecutor.commitBatches(storedBatch2Info, [batch3InfoTwoUpgradeTx])).wait();

    expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(3);
  });

  it("Should commit successfully when batch was reverted and reupgraded", async () => {
    await (await proxyExecutor.revertBatches(2)).wait();
    const timestamp = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    const systemLogs = createSystemLogs();
    systemLogs.push(
      constructL2Log(
        true,
        L2_BOOTLOADER_ADDRESS,
        SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
        l2UpgradeTxHash
      )
    );
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch3InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 3,
        timestamp,
      },
      systemLogs
    );

    const commitReceipt = await (await proxyExecutor.commitBatches(storedBatch2Info, [batch3InfoTwoUpgradeTx])).wait();

    expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(3);
    const commitment = commitReceipt.events[0].args.commitment;
    const newBatchStoredInfo = getBatchStoredInfo(batch3InfoTwoUpgradeTx, commitment);
    await makeExecutedEqualCommitted(proxyExecutor, storedBatch2Info, [newBatchStoredInfo], []);

    storedBatch2Info = newBatchStoredInfo;
  });

  it("Should successfully commit a sequential upgrade", async () => {
    expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);
    await (
      await executeUpgrade(chainId, proxyGetters, stateTransitionManager, proxyAdmin, {
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 5 + 1, 0),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    ).wait();

    const timestamp = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    const systemLogs = createSystemLogs();
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch4InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 4,
        timestamp,
      },
      systemLogs
    );

    const commitReceipt = await (await proxyExecutor.commitBatches(storedBatch2Info, [batch4InfoTwoUpgradeTx])).wait();
    const commitment = commitReceipt.events[0].args.commitment;
    const newBatchStoredInfo = getBatchStoredInfo(batch4InfoTwoUpgradeTx, commitment);

    expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);

    await makeExecutedEqualCommitted(proxyExecutor, storedBatch2Info, [newBatchStoredInfo], []);

    storedBatch2Info = newBatchStoredInfo;

    expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);
  });

  it("Should successfully commit custom upgrade", async () => {
    const upgradeReceipt = await (
      await executeCustomUpgrade(chainId, proxyGetters, proxyAdmin, stateTransitionManager, {
        newProtocolVersion: addToProtocolVersion(initialProtocolVersion, 6 + 1, 0),
        l2ProtocolUpgradeTx: noopUpgradeTransaction,
      })
    ).wait();
    const customUpgradeFactory = await hardhat.ethers.getContractFactory("CustomUpgradeTest");

    const upgradeEvents = upgradeReceipt.logs.map((log) => {
      // Not all events can be parsed there, but we don't care about them
      try {
        const event = customUpgradeFactory.interface.parseLog(log);
        const parsedArgs = event.args;
        return {
          name: event.name,
          args: parsedArgs,
        };
      } catch (_) {
        // @ts-ignore
      }
    });

    const timestamp = (await hardhat.ethers.provider.getBlock("latest")).timestamp;
    const systemLogs = createSystemLogs();
    systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      ethers.utils.hexlify(storedBatch2Info.batchHash)
    );

    const batch5InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
      storedBatch2Info,
      {
        batchNumber: 5,
        timestamp,
      },
      systemLogs
    );

    const commitReceipt = await (await proxyExecutor.commitBatches(storedBatch2Info, [batch5InfoTwoUpgradeTx])).wait();
    const commitment = commitReceipt.events[0].args.commitment;
    const newBatchStoredInfo = getBatchStoredInfo(batch5InfoTwoUpgradeTx, commitment);

    await makeExecutedEqualCommitted(proxyExecutor, storedBatch2Info, [newBatchStoredInfo], []);

    storedBatch2Info = newBatchStoredInfo;

    expect(upgradeEvents[1].name).to.equal("Test");
  });
});

async function buildCommitBatchInfo(
  prevInfo: StoredBatchInfo,
  info: CommitBatchInfoWithTimestamp
): Promise<CommitBatchInfo> {
  const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock("latest")).timestamp;
  const systemLogs = createSystemLogs(info.priorityOperationsHash, info.numberOfLayer1Txs, prevInfo.batchHash);
  systemLogs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
    true,
    L2_SYSTEM_CONTEXT_ADDRESS,
    SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
    packBatchTimestampAndBatchTimestamp(timestamp, timestamp)
  );

  return {
    timestamp,
    indexRepeatedStorageChanges: 0,
    newStateRoot: ethers.utils.randomBytes(32),
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    systemLogs: ethers.utils.hexConcat(systemLogs),
    pubdataCommitments: `0x${"0".repeat(130)}`,
    bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
    eventsQueueStateHash: ethers.utils.randomBytes(32),
    ...info,
  };
}

async function buildCommitBatchInfoWithCustomLogs(
  prevInfo: StoredBatchInfo,
  info: CommitBatchInfoWithTimestamp,
  systemLogs: string[]
): Promise<CommitBatchInfo> {
  const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock("latest")).timestamp;
  systemLogs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
    true,
    L2_SYSTEM_CONTEXT_ADDRESS,
    SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
    packBatchTimestampAndBatchTimestamp(timestamp, timestamp)
  );

  return {
    timestamp,
    indexRepeatedStorageChanges: 0,
    newStateRoot: ethers.utils.randomBytes(32),
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    systemLogs: ethers.utils.hexConcat(systemLogs),
    pubdataCommitments: `0x${"0".repeat(130)}`,
    bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
    eventsQueueStateHash: ethers.utils.randomBytes(32),
    ...info,
  };
}

function buildVerifierParams(params: Partial<VerifierParams>): VerifierParams {
  return {
    recursionNodeLevelVkHash: ethers.constants.HashZero,
    recursionLeafLevelVkHash: ethers.constants.HashZero,
    recursionCircuitsSetVksHash: ethers.constants.HashZero,
    ...params,
  };
}

type PartialProposedUpgrade = Partial<ProposedUpgrade>;

function buildProposeUpgrade(proposedUpgrade: PartialProposedUpgrade): ProposedUpgrade {
  const newProtocolVersion = proposedUpgrade.newProtocolVersion || 0;
  return {
    l2ProtocolUpgradeTx: buildL2CanonicalTransaction({ nonce: newProtocolVersion }),
    bootloaderHash: ethers.constants.HashZero,
    defaultAccountHash: ethers.constants.HashZero,
    verifier: ethers.constants.AddressZero,
    verifierParams: buildVerifierParams({}),
    l1ContractsUpgradeCalldata: "0x",
    postUpgradeCalldata: "0x",
    upgradeTimestamp: ethers.constants.Zero,
    factoryDeps: [],
    newProtocolVersion,
    ...proposedUpgrade,
  };
}

async function executeUpgrade(
  chainId: BigNumberish,
  proxyGetters: GettersFacet,
  stateTransitionManager: StateTransitionManager,
  proxyAdmin: AdminFacet,
  partialUpgrade: Partial<ProposedUpgrade>,
  contractFactory?: ethers.ethers.ContractFactory
) {
  if (partialUpgrade.newProtocolVersion == null) {
    const { 0: major, 1: minor, 2: patch } = await proxyGetters.getSemverProtocolVersion();
    const newVersion = packSemver(major, minor + 1, patch);
    partialUpgrade.newProtocolVersion = newVersion;
  }
  const upgrade = buildProposeUpgrade(partialUpgrade);

  const defaultUpgradeFactory = contractFactory
    ? contractFactory
    : await hardhat.ethers.getContractFactory("DefaultUpgrade");

  const defaultUpgrade = await defaultUpgradeFactory.deploy();
  const diamondUpgradeInit = DefaultUpgradeFactory.connect(defaultUpgrade.address, defaultUpgrade.signer);

  const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData("upgrade", [upgrade]);

  const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

  const oldProtocolVersion = await proxyGetters.getProtocolVersion();
  // This promise will be handled in the tests
  (
    await stateTransitionManager.setNewVersionUpgrade(
      diamondCutData,
      oldProtocolVersion,
      999999999999,
      partialUpgrade.newProtocolVersion
    )
  ).wait();
  return proxyAdmin.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
}

// we rollback the protocolVersion ( we don't clear the upgradeHash mapping, but that is ok)
async function rollBackToVersion(
  protocolVersion: string,
  stateTransition: StateTransitionManager,
  partialUpgrade: Partial<ProposedUpgrade>
) {
  partialUpgrade.newProtocolVersion = protocolVersion;

  const upgrade = buildProposeUpgrade(partialUpgrade);

  const defaultUpgradeFactory = await hardhat.ethers.getContractFactory("DefaultUpgrade");

  const defaultUpgrade = await defaultUpgradeFactory.deploy();
  const diamondUpgradeInit = DefaultUpgradeFactory.connect(defaultUpgrade.address, defaultUpgrade.signer);

  const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData("upgrade", [upgrade]);

  const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

  // This promise will be handled in the tests
  (
    await stateTransition.setNewVersionUpgrade(
      diamondCutData,
      (parseInt(protocolVersion) - 1).toString(),
      999999999999,
      protocolVersion
    )
  ).wait();
}

async function executeCustomUpgrade(
  chainId: BigNumberish,
  proxyGetters: GettersFacet,
  proxyAdmin: AdminFacet,
  stateTransition: StateTransitionManager,
  partialUpgrade: Partial<ProposedUpgrade>,
  contractFactory?: ethers.ethers.ContractFactory
) {
  if (partialUpgrade.newProtocolVersion == null) {
    const newVersion = (await proxyGetters.getProtocolVersion()).add(1);
    partialUpgrade.newProtocolVersion = newVersion;
  }
  const upgrade = buildProposeUpgrade(partialUpgrade);

  const upgradeFactory = contractFactory
    ? contractFactory
    : await hardhat.ethers.getContractFactory("CustomUpgradeTest");

  const customUpgrade = await upgradeFactory.deploy();
  const diamondUpgradeInit = CustomUpgradeTestFactory.connect(customUpgrade.address, customUpgrade.signer);

  const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData("upgrade", [upgrade]);

  const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);
  const oldProtocolVersion = await proxyGetters.getProtocolVersion();

  // This promise will be handled in the tests
  (
    await stateTransition.setNewVersionUpgrade(
      diamondCutData,
      oldProtocolVersion,
      999999999999,
      partialUpgrade.newProtocolVersion
    )
  ).wait();
  return proxyAdmin.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
}
