import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import * as hardhat from "hardhat";
import { getTokens, ADDRESS_ONE} from "../../scripts/utils";
import type { L1WethBridge, WETH9 } from "../../typechain";
import { L1WethBridgeFactory, WETH9Factory } from "../../typechain";

import type { IBridgehub } from "../../typechain/IBridgehub";
import { getCallRevertReason, initialDeployment, CONTRACTS_LATEST_PROTOCOL_VERSION , executeUpgrade} from "./utils";

import { startInitializeChain } from "../../src.ts/weth-initialize";


import * as fs from "fs";
// import { EraLegacyChainId, EraLegacyDiamondProxyAddress } from "../../src.ts/deploy";
import { hashL2Bytecode } from "../../src.ts/utils";

import { Interface } from "ethers/lib/utils";
import type { Address } from "zksync-web3/build/src/types";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

export async function create2DeployFromL1(
  bridgehub: IBridgehub,
  chainId: ethers.BigNumberish,
  walletAddress: Address,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish
) {
  const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);
  const gasPrice = await bridgehub.provider.getGasPrice();
  const expectedCost = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  await bridgehub.requestL2Transaction(
    chainId,
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    expectedCost,
    0,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    [bytecode],
    walletAddress,
    { value: expectedCost, gasPrice }
  );
}

describe("WETH Bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let bridgeProxy: L1WethBridge;
  let l1Weth: WETH9;
  const functionSignature = "0x6c0960f9";
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic4, "m/44'/60'/0'/0/1").connect(owner.provider);
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

    // note we can use initialDeployment so we don't go into deployment details here
    const deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, []);

    chainId = deployer.chainId;

    const tokens = getTokens("hardhat");
    const l1WethTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    l1Weth = WETH9Factory.connect(l1WethTokenAddress, owner);
    // prepare the bridge

    bridgeProxy = L1WethBridgeFactory.connect(deployer.addresses.Bridges.WethBridgeProxy, deployWallet);
    const nonce = await deployWallet.getTransactionCount(); 

    await startInitializeChain(deployer, deployWallet, chainId.toString(), nonce, gasPrice);

    const l1WethBridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1WethBridge").abi);
    const upgradeCall =  l1WethBridgeInterface.encodeFunctionData(
      "initializeChainGovernance(uint256,address,address)",  
      [chainId, ADDRESS_ONE, ADDRESS_ONE]);

    await executeUpgrade(deployer,deployWallet, bridgeProxy.address, 0, upgradeCall);
  });

  it("Check startInitializeChain", async () => {

    const txHash = await bridgeProxy.bridgeImplDeployOnL2TxHash(chainId);

    expect(txHash).not.equal(ethers.constants.HashZero);
  })

  it("Should not allow depositing zero WETH", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .deposit(
          chainId,
          await randomSigner.getAddress(),
          await bridgeProxy.l1WethAddress(),
          0,
          0,
          0,
          0,
          ethers.constants.AddressZero
        )
    );

    expect(revertReason).equal("L1WETH Bridge: Amount cannot be zero");
  });

  it("Should deposit successfully", async () => {
    await l1Weth.connect(randomSigner).deposit({ value: 100 });
    await (await l1Weth.connect(randomSigner).approve(bridgeProxy.address, 100)).wait();
    await bridgeProxy
      .connect(randomSigner)
      .deposit(
        chainId,
        await randomSigner.getAddress(),
        l1Weth.address,
        100,
        100,
        1000000,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        await randomSigner.getAddress(),
        { value: ethers.constants.WeiPerEther }
      );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("Incorrect ETH message with additional data length");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("Incorrect message function selector");
  });

  // not valid anymore, weth bridge is also eth bridge, receiver gets the eth. 
  // it("Should revert on finalizing a withdrawal with wrong receiver", async () => {
  //   const revertReason = await getCallRevertReason(
  //     bridgeProxy
  //       .connect(randomSigner)
  //       .finalizeWithdrawal(
  //         chainId,
  //         0,
  //         0,
  //         0,
  //         ethers.utils.hexConcat([functionSignature, ethers.utils.randomBytes(92)]),
  //         [ethers.constants.HashZero]
  //       )
  //   );
  //   expect(revertReason).equal("pi");
  // });

  it("Should revert on finalizing a withdrawal with wrong L2 sender", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .finalizeWithdrawal(
          chainId,
          0,
          0,
          0,
          ethers.utils.hexConcat([
            functionSignature,
            bridgeProxy.address,
            ethers.utils.randomBytes(32),
            ethers.utils.randomBytes(40),
          ]),
          [ethers.constants.HashZero]
        )
    );
    expect(revertReason).equal("The withdrawal was not initiated by L2 bridge");
  });
});
