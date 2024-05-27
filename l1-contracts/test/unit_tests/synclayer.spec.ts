import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { Bridgehub, StateTransitionManager } from "../../typechain";
import { AdminFacetFactory, BridgehubFactory, StateTransitionManagerFactory } from "../../typechain";

import {
  initialTestnetDeploymentProcess,
  defaultDeployerForTests,
  registerHyperchainWithBridgeRegistration,
} from "../../src.ts/deploy-test-process";
import { ethTestConfig, DIAMOND_CUT_DATA_ABI_STRING, HYPERCHAIN_COMMITMENT_ABI_STRING } from "../../src.ts/utils";
import {
  getAddressFromEnv,
  getNumberFromEnv,
  ADDRESS_ONE,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
} from "../../src.ts/utils";
import { SYSTEM_CONFIG } from "../../scripts/utils";

import type { Deployer } from "../../src.ts/deploy";

describe("Synclayer", function () {
  let bridgehub: Bridgehub;
  let stateTransition: StateTransitionManager;
  let owner: ethers.Signer;
  let deployer: Deployer;
  let syncLayerDeployer: Deployer;
  // const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
  // const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
  // let forwarder: Forwarder;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

  before(async () => {
    [owner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    const gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: await owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, []);

    chainId = deployer.chainId;

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    stateTransition = StateTransitionManagerFactory.connect(
      deployer.addresses.StateTransition.StateTransitionProxy,
      deployWallet
    );

    syncLayerDeployer = await defaultDeployerForTests(deployWallet, ownerAddress);
    syncLayerDeployer.chainId = 10;
    await registerHyperchainWithBridgeRegistration(
      syncLayerDeployer,
      false,
      [],
      gasPrice,
      undefined,
      syncLayerDeployer.chainId.toString()
    );

    // For tests, the chainId is 9
    deployer.chainId = 9;
  });

  it("Check register synclayer", async () => {
    await syncLayerDeployer.registerSyncLayer();
  });

  it("Check start move chain to synclayer", async () => {
    const gasPrice = await owner.provider.getGasPrice();
    await deployer.moveChainToSyncLayer(syncLayerDeployer.chainId.toString(), gasPrice, false);
  });

  it("Check l2 registration", async () => {
    const stm = deployer.stateTransitionManagerContract(deployer.deployWallet);
    const gasPrice = await deployer.deployWallet.provider.getGasPrice();
    const value = (
      await bridgehub.l2TransactionBaseCost(chainId, gasPrice, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA)
    ).mul(5);
    const baseTokenAddress = await bridgehub.baseToken(chainId);
    const ethIsBaseToken = baseTokenAddress == ADDRESS_ONE;

    const stmDeploymentTracker = deployer.stmDeploymentTracker(deployer.deployWallet);
    await deployer.executeUpgrade(
      bridgehub.address,
      value,
      bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
        {
          chainId,
          mintValue: value,
          l2Value: 0,
          l2GasLimit: priorityTxMaxGasLimit,
          l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
          refundRecipient: deployer.deployWallet.address,
          secondBridgeAddress: stmDeploymentTracker.address,
          secondBridgeValue: 0,
          secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
            ["bool", "address", "address"],
            [false, stm.address, stm.address]
          ),
        },
      ])
    );
    // console.log("STM asset registered in L2SharedBridge on SL");
    await deployer.executeUpgrade(
      bridgehub.address,
      value,
      bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
        {
          chainId,
          mintValue: value,
          l2Value: 0,
          l2GasLimit: priorityTxMaxGasLimit,
          l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
          refundRecipient: deployer.deployWallet.address,
          secondBridgeAddress: stmDeploymentTracker.address,
          secondBridgeValue: 0,
          secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
            ["bool", "address", "address"],
            [true, stm.address, stm.address]
          ),
        },
      ])
    );
    // console.log("STM asset registered in L2 Bridgehub on SL");
  });

  it("Check finish move chain to l1", async () => {
    const syncLayerChainId = syncLayerDeployer.chainId;
    const mintChainId = 11;
    const assetInfo = await bridgehub.stmAssetInfo(deployer.addresses.StateTransition.StateTransitionProxy);
    const diamondCutData = await deployer.initialZkSyncHyperchainDiamondCut();
    const initialDiamondCut = new ethers.utils.AbiCoder().encode([DIAMOND_CUT_DATA_ABI_STRING], [diamondCutData]);

    const adminFacet = AdminFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
      deployer.deployWallet
    );

    // const chainCommitment = {
    //   totalBatchesExecuted: 0,
    //   totalBatchesVerified: 0,
    //   totalBatchesCommitted:0,
    //   priorityQueueHead: 0,
    //   priorityQueueTxs: [
    //     {
    //       canonicalTxHash: '0xea79e9b7c3c46a76174b3aea3760570a7e18b593d2b5a087fce52cee95d2d57e',
    //       expirationTimestamp: "1716557077",
    //       layer2Tip: 0
    //   }],
    //   l2SystemContractsUpgradeTxHash: ethers.constants.HashZero,
    //   l2SystemContractsUpgradeBatchNumber:0 ,
    //   batchHashes: ['0xcd4e278573a3b2076a81f91b97e2dd0c85882d9f735ad81dc34b509033671e7b']}
    const chainData = ethers.utils.defaultAbiCoder.encode(
      [HYPERCHAIN_COMMITMENT_ABI_STRING],
      [await adminFacet._prepareChainCommitment()]
    );
    // const chainData = await adminFacet.readChainCommitment();
    const stmData = ethers.utils.defaultAbiCoder.encode(
      ["address", "address", "uint256", "bytes"],
      [ADDRESS_ONE, deployer.deployWallet.address, 21, initialDiamondCut]
    );
    const bridgehubMintData = ethers.utils.defaultAbiCoder.encode(
      ["uint256", "bytes", "bytes"],
      [mintChainId, stmData, chainData]
    );
    await bridgehub.bridgeMint(syncLayerChainId, assetInfo, bridgehubMintData);
    expect(await stateTransition.getHyperchain(mintChainId)).to.not.equal(ethers.constants.AddressZero);
  });
});
