import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { Bridgehub } from "../../typechain";
import { BridgehubFactory } from "../../typechain";

import {
  initialTestnetDeploymentProcess,
  defaultDeployerForTests,
  registerZKChainWithBridgeRegistration,
} from "../../src.ts/deploy-test-process";
import {
  ethTestConfig,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  L2_BRIDGEHUB_ADDRESS,
} from "../../src.ts/utils";
import { SYSTEM_CONFIG } from "../../scripts/utils";

import type { Deployer } from "../../src.ts/deploy";

describe("Gateway", function () {
  let bridgehub: Bridgehub;
  // let stateTransition: ChainTypeManager;
  let owner: ethers.Signer;
  let migratingDeployer: Deployer;
  let gatewayDeployer: Deployer;
  // const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
  // const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
  // let forwarder: Forwarder;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;
  const mintChainId = 11;

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

    migratingDeployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, []);
    // We will use the chain admin as the admin to be closer to the production environment
    await migratingDeployer.transferAdminFromDeployerToChainAdmin();

    chainId = migratingDeployer.chainId;

    bridgehub = BridgehubFactory.connect(migratingDeployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    gatewayDeployer = await defaultDeployerForTests(deployWallet, ownerAddress);
    gatewayDeployer.chainId = 10;
    await registerZKChainWithBridgeRegistration(
      gatewayDeployer,
      false,
      [],
      gasPrice,
      undefined,
      gatewayDeployer.chainId.toString()
    );

    // For tests, the chainId is 9
    migratingDeployer.chainId = 9;
  });

  it("Check register synclayer", async () => {
    await gatewayDeployer.registerSettlementLayer();
  });

  it("Check start move chain to synclayer", async () => {
    const gasPrice = await owner.provider.getGasPrice();
    await migratingDeployer.moveChainToGateway(gatewayDeployer.chainId.toString(), gasPrice);
    expect(await bridgehub.settlementLayer(migratingDeployer.chainId)).to.equal(gatewayDeployer.chainId);
  });

  it("Check l2 registration", async () => {
    const ctm = migratingDeployer.chainTypeManagerContract(migratingDeployer.deployWallet);
    const gasPrice = await migratingDeployer.deployWallet.provider.getGasPrice();
    const value = (
      await bridgehub.l2TransactionBaseCost(chainId, gasPrice, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA)
    ).mul(10);

    const ctmDeploymentTracker = migratingDeployer.ctmDeploymentTracker(migratingDeployer.deployWallet);
    const assetRouter = migratingDeployer.defaultSharedBridge(migratingDeployer.deployWallet);
    const assetId = await bridgehub.ctmAssetIdFromChainId(chainId);

    await migratingDeployer.executeUpgrade(
      bridgehub.address,
      value,
      bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
        {
          chainId,
          mintValue: value,
          l2Value: 0,
          l2GasLimit: priorityTxMaxGasLimit,
          l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
          refundRecipient: migratingDeployer.deployWallet.address,
          secondBridgeAddress: assetRouter.address,
          secondBridgeValue: 0,
          secondBridgeCalldata:
            "0x02" +
            ethers.utils.defaultAbiCoder.encode(["bytes32", "address"], [assetId, L2_BRIDGEHUB_ADDRESS]).slice(2),
        },
      ])
    );
    await migratingDeployer.executeUpgrade(
      bridgehub.address,
      value,
      bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
        {
          chainId,
          mintValue: value,
          l2Value: 0,
          l2GasLimit: priorityTxMaxGasLimit,
          l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
          refundRecipient: migratingDeployer.deployWallet.address,
          secondBridgeAddress: ctmDeploymentTracker.address,
          secondBridgeValue: 0,
          secondBridgeCalldata:
            "0x01" + ethers.utils.defaultAbiCoder.encode(["address", "address"], [ctm.address, ctm.address]).slice(2),
        },
      ])
    );
    // console.log("CTM asset registered in L2 Bridgehub on SL");
  });

  it("Check start message to L3 on L1", async () => {
    const amount = ethers.utils.parseEther("2");
    await bridgehub.requestL2TransactionDirect(
      {
        chainId: migratingDeployer.chainId,
        mintValue: amount,
        l2Contract: ethers.constants.AddressZero,
        l2Value: 0,
        l2Calldata: "0x",
        l2GasLimit: priorityTxMaxGasLimit,
        l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        factoryDeps: [],
        refundRecipient: ethers.constants.AddressZero,
      },
      { value: amount }
    );
  });

  it("Check forward message to L3 on SL", async () => {
    const tx = {
      txType: 255,
      from: ethers.constants.AddressZero,
      to: ethers.constants.AddressZero,
      gasLimit: priorityTxMaxGasLimit,
      gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      maxFeePerGas: 1,
      maxPriorityFeePerGas: 0,
      paymaster: 0,
      // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
      nonce: 0,
      value: 0,
      reserved: [0 as ethers.BigNumberish, 0, 0, 0] as [
        ethers.BigNumberish,
        ethers.BigNumberish,
        ethers.BigNumberish,
        ethers.BigNumberish,
      ],
      data: "0x",
      signature: ethers.constants.HashZero,
      factoryDeps: [],
      paymasterInput: "0x",
      reservedDynamic: "0x",
    };
    bridgehub.forwardTransactionOnGateway(mintChainId, tx, [], ethers.constants.HashZero, 0);
  });
});
