import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { ethTestConfig } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";

import { upgradeToHyperchains } from "../../src.ts/hyperchain-upgrade";
import type { FacetCut } from "../../src.ts/diamondCut";
import { Action, facetCut } from "../../src.ts/diamondCut";

import type { ExecutorFacet, GettersFacet } from "../../typechain";
import { DummyAdminFacetFactory, ExecutorFacetFactory, GettersFacetFactory } from "../../typechain";
import type { CommitBatchInfo, StoredBatchInfo } from "./utils";
import {
  buildCommitBatchInfoWithUpgrade,
  genesisStoredBatchInfo,
  EMPTY_STRING_KECCAK,
  makeExecutedEqualCommitted,
  getBatchStoredInfo,
} from "./utils";

// note this test presumes that it is ok to start out with the new contracts, and upgrade them to themselves
describe("Hyperchain migration test", function () {
  let owner: ethers.Signer;
  let deployer: Deployer;
  let gasPrice;

  let proxyExecutor: ExecutorFacet;
  let proxyGetters: GettersFacet;

  let batch1InfoChainIdUpgrade: CommitBatchInfo;
  let storedBatch1InfoChainIdUpgrade: StoredBatchInfo;

  let extraFacet: FacetCut;

  before(async () => {
    [owner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: await owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    const dummyAdminFacetFactory = await hardhat.ethers.getContractFactory("DummyAdminFacet");
    const dummyAdminfFacetContract = await dummyAdminFacetFactory.deploy();
    extraFacet = facetCut(dummyAdminfFacetContract.address, dummyAdminfFacetContract.interface, Action.Add, true);

    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [extraFacet]);

    proxyExecutor = ExecutorFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    proxyGetters = GettersFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    const dummyAdminFacet = DummyAdminFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
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
    // console.log("committing batch1InfoChainIdUpgrade");
    const commitReceipt = await (
      await proxyExecutor.commitBatches(genesisStoredBatchInfo(), [batch1InfoChainIdUpgrade])
    ).wait();
    const commitment = commitReceipt.events[0].args.commitment;
    storedBatch1InfoChainIdUpgrade = getBatchStoredInfo(batch1InfoChainIdUpgrade, commitment);
    await makeExecutedEqualCommitted(proxyExecutor, genesisStoredBatchInfo(), [storedBatch1InfoChainIdUpgrade], []);
  });

  it("Start upgrade", async () => {
    await upgradeToHyperchains(deployer, gasPrice);
  });
});
