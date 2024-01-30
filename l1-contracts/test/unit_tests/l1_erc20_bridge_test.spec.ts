import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import { Interface } from "ethers/lib/utils";
import * as hardhat from "hardhat";

import * as fs from "fs";
import { ADDRESS_ONE, getTokens } from "../../scripts/utils";
import type { Deployer } from "../../src.ts/deploy";
import type { Bridgehub, L1ERC20Bridge } from "../../typechain";
import { BridgehubFactory, L1ERC20BridgeFactory, TestnetERC20TokenFactory } from "../../typechain";
import type { IL1Bridge } from "../../typechain/IL1Bridge";
import { IL1BridgeFactory } from "../../typechain/IL1BridgeFactory";
import {
  CONTRACTS_LATEST_PROTOCOL_VERSION,
  depositERC20,
  executeUpgrade,
  getCallRevertReason,
  initialDeployment,
} from "./utils";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

describe("L1ERC20Bridge tests", function () {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let l1ERC20BridgeAddress: string;
  let l1ERC20Bridge: IL1Bridge;
  let l1ERC20BridgeInit: L1ERC20Bridge;
  let erc20TestToken: ethers.Contract;
  let bridgehub: Bridgehub;
  let chainId = "0";
  const functionSignature = "0x11a2ccc1";

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    const gasPrice = await owner.provider.getGasPrice();

    deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();
    process.env.ETH_CLIENT_CHAIN_ID = (await deployWallet.getChainId()).toString();

    const tx = {
      from: owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);

    deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, []);
    chainId = deployer.chainId.toString();

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    l1ERC20BridgeAddress = deployer.addresses.Bridges.ERC20BridgeProxy;
    l1ERC20BridgeInit = L1ERC20BridgeFactory.connect(l1ERC20BridgeAddress, deployWallet);

    l1ERC20Bridge = IL1BridgeFactory.connect(l1ERC20BridgeAddress, deployWallet);

    const tokens = getTokens("hardhat");
    const tokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    erc20TestToken = TestnetERC20TokenFactory.connect(tokenAddress, owner);

    await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits("10000", 18));
    await erc20TestToken.connect(randomSigner).approve(l1ERC20BridgeAddress, ethers.utils.parseUnits("10000", 18));
  });

  it("Check should initialize through governance", async () => {
    const l1ERC20BridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1ERC20Bridge").abi);
    const upgradeCall = l1ERC20BridgeInterface.encodeFunctionData(
      "initializeChainGovernance(uint256,address,address)",
      [chainId, ADDRESS_ONE, ADDRESS_ONE]
    );

    const txHash = await executeUpgrade(deployer, deployWallet, l1ERC20Bridge.address, 0, upgradeCall);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Should not allow depositing zero amount", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .deposit(
          chainId,
          await randomSigner.getAddress(),
          erc20TestToken.address,
          0,
          0,
          0,
          0,
          ethers.constants.AddressZero
        )
    );
    expect(revertReason).equal("2T");
  });

  it("Should deposit successfully", async () => {
    const depositorAddress = await randomSigner.getAddress();
    await depositERC20(
      l1ERC20Bridge.connect(randomSigner),
      bridgehub,
      chainId,
      depositorAddress,
      erc20TestToken.address,
      ethers.utils.parseUnits("800", 18),
      10000000
    );
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [ethers.constants.HashZero])
    );
    expect(revertReason).equal("EB w msg len");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(76), [ethers.constants.HashZero])
    );
    expect(revertReason).equal("W msg f slctr");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 10, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xx");
  });

  it("Should revert on finalizing a withdrawal with wrong length of proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, [])
    );
    expect(revertReason).equal("xc");
  });

  it("Should revert on finalizing a withdrawal with wrong proof", async () => {
    const l1Receiver = await randomSigner.getAddress();
    const l2ToL1message = ethers.utils.hexConcat([
      functionSignature,
      l1Receiver,
      erc20TestToken.address,
      ethers.constants.HashZero,
    ]);
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, Array(9).fill(ethers.constants.HashZero))
    );
    expect(revertReason).equal("EB withd w pf");
  });
});
