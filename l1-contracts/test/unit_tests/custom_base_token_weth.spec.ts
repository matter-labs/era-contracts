import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import * as hardhat from "hardhat";
import { ADDRESS_ONE, getTokens } from "../../scripts/utils";
import type { L1WethBridge, TestnetERC20Token, WETH9 } from "../../typechain";
import { L1WethBridgeFactory, TestnetERC20TokenFactory, WETH9Factory } from "../../typechain";

import type { IBridgehub } from "../../typechain/IBridgehub";
import { IBridgehubFactory } from "../../typechain/IBridgehubFactory";
import { CONTRACTS_LATEST_PROTOCOL_VERSION, executeUpgrade, getCallRevertReason, initialDeployment } from "./utils";

import { startWethBridgeInitOnChain } from "../../src.ts/weth-initialize";

import * as fs from "fs";
// import { EraLegacyChainId, EraLegacyDiamondProxyAddress } from "../../src.ts/deploy";
import { hashL2Bytecode } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";

import { Interface } from "ethers/lib/utils";
import type { IL1Bridge } from "../../typechain/IL1Bridge";
import { IL1BridgeFactory } from "../../typechain/IL1BridgeFactory";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

export async function create2DeployFromL1(
  bridgehub: IBridgehub,
  chainId: ethers.BigNumberish,
  walletAddress: string,
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
    {
      chainId,
      l2Contract: DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
      mintValue: expectedCost,
      l2Value: 0,
      l2Calldata: calldata,
      l2GasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: [bytecode],
      refundRecipient: walletAddress,
    },
    { value: expectedCost, gasPrice }
  );
}

describe("Custom base token weth tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let l1ERC20Bridge: IL1Bridge;
  let bridgehub: IBridgehub;
  let l1WethBridge: IL1Bridge;
  let l1WethBridgeInit: L1WethBridge;
  let baseToken: TestnetERC20Token;
  let baseTokenAddress: string;
  let wethTokenAddress: string;
  let wethToken: WETH9;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID ? parseInt(process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID) : 270;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic4, "m/44'/60'/0'/0/1").connect(owner.provider);
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
    deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, [], "BAT");
    chainId = deployer.chainId;
    bridgehub = IBridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    const tokens = getTokens("hardhat");
    baseTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "BAT")!.address;
    baseToken = TestnetERC20TokenFactory.connect(baseTokenAddress, owner);

    wethTokenAddress = await deployer.defaultWethBridge(deployWallet).l1WethAddress();
    wethToken = WETH9Factory.connect(wethTokenAddress, owner);

    // prepare the bridges
    l1ERC20Bridge = IL1BridgeFactory.connect(deployer.addresses.Bridges.ERC20BridgeProxy, deployWallet);
    l1WethBridge = IL1BridgeFactory.connect(deployer.addresses.Bridges.WethBridgeProxy, deployWallet);
    l1WethBridgeInit = L1WethBridgeFactory.connect(deployer.addresses.Bridges.WethBridgeProxy, deployWallet);
  });

  it("Should have correct base token", async () => {
    // we should still be able to deploy the erc20 bridge
    const baseTokenAddressInBridgehub = await bridgehub.baseToken(chainId);
    const baseTokenBridgeAddress = await bridgehub.baseTokenBridge(chainId);
    expect(baseTokenAddress).equal(baseTokenAddressInBridgehub);
    expect(l1ERC20Bridge.address).equal(baseTokenBridgeAddress);
  });

  it("Check startWethBridgeInitOnChain", async () => {
    const nonce = await deployWallet.getTransactionCount();
    const gasPrice = await owner.provider.getGasPrice();

    await startWethBridgeInitOnChain(deployer, deployWallet, chainId.toString(), nonce, gasPrice);

    const txHash = await l1WethBridgeInit.bridgeProxyDeployOnL2TxHash(chainId);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Check should initialize through governance", async () => {
    const l1WethBridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1WethBridge").abi);
    const upgradeCall = l1WethBridgeInterface.encodeFunctionData("initializeChainGovernance(uint256,address,address)", [
      chainId,
      ADDRESS_ONE,
      ADDRESS_ONE,
    ]);

    const txHash = await executeUpgrade(deployer, deployWallet, l1WethBridgeInit.address, 0, upgradeCall);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Should not allow direct deposits", async () => {
    const revertReason = await getCallRevertReason(
      l1WethBridge
        .connect(randomSigner)
        .deposit(chainId, await randomSigner.getAddress(), wethTokenAddress, 0, 0, 0, 0, ethers.constants.AddressZero)
    );

    expect(revertReason).equal(
      "L1WETH Bridge: Direct deposit via requestL2Transaction only available for Eth based chains"
    );
  });

  it("Should deposit weth token successfully twoBridges method", async () => {
    const wethTokenAmount = ethers.utils.parseUnits("800", 18);
    const baseTokenAmount = ethers.utils.parseUnits("800", 18);

    await (await wethToken.connect(randomSigner).deposit({ value: wethTokenAmount })).wait();
    await (await wethToken.connect(randomSigner).approve(l1WethBridge.address, wethTokenAmount)).wait();

    await (await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), baseTokenAmount)).wait();
    await (await baseToken.connect(randomSigner).approve(l1ERC20Bridge.address, baseTokenAmount)).wait();

    await bridgehub.connect(randomSigner).requestL2TransactionTwoBridges({
      chainId,
      mintValue: baseTokenAmount,
      l2Value: 1,
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      refundRecipient: await randomSigner.getAddress(),
      secondBridgeAddress: l1WethBridge.address,
      secondBridgeSelector: l1WethBridge.interface.getSighash("bridgehubDeposit"),
      secondBridgeValue: 0,
      secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "address"],
        [wethTokenAddress, wethTokenAmount, await randomSigner.getAddress()]
      ),
    });
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1WethBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("Incorrect ETH message with additional data length");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      l1WethBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("Incorrect message function selector");
  });
});
