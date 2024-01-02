import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import { Interface } from "ethers/lib/utils";
import * as hardhat from "hardhat";

import * as fs from "fs";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-web3/build/src/utils";
import type { IBridgehub } from "../../typechain/IBridgehub";
import type { TestnetERC20Token, Bridgehub } from "../../typechain";
import { TestnetERC20TokenFactory, BridgehubFactory, L1ERC20BridgeFactory, L1ERC20Bridge, GovernanceFactory } from "../../typechain";
import type { IL1Bridge } from "../../typechain/IL1Bridge";
import { IL1BridgeFactory } from "../../typechain/IL1BridgeFactory";
import { getCallRevertReason, initialDeployment, CONTRACTS_LATEST_PROTOCOL_VERSION, executeUpgrade } from "./utils";
import { ADDRESS_ONE, getTokens} from "../../scripts/utils";
import { startInitializeChain } from "../../src.ts/erc20-initialize";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

describe("L1ERC20Bridge tests", function () {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let l1ERC20BridgeAddress: string;
  let l1ERC20Bridge: IL1Bridge;
  let l1ERC20BridgeInit: L1ERC20Bridge;
  // let erc20TestToken: TestnetERC20Token;
  let erc20TestToken: ethers.Contract;
  let l1Erc20BridgeContract: ethers.Contract;
  let bridgehub: Bridgehub;
  let chainId = "0";

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    const gasPrice = await owner.provider.getGasPrice();

    const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(owner.provider);
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

    const deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, []);
    chainId = deployer.chainId.toString();

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    // const l1Erc20BridgeFactory = await hardhat.ethers.getContractFactory("L1ERC20Bridge");
    // l1Erc20BridgeContract = await l1Erc20BridgeFactory.deploy(deployer.addresses.Bridgehub.BridgehubProxy, 0);
    l1ERC20BridgeAddress = deployer.addresses.Bridges.ERC20BridgeProxy;
    l1ERC20BridgeInit = L1ERC20BridgeFactory.connect(l1ERC20BridgeAddress, deployWallet);

    l1ERC20Bridge = IL1BridgeFactory.connect(l1ERC20BridgeAddress, deployWallet);


    // const testnetERC20TokenFactory = await hardhat.ethers.getContractFactory("TestnetERC20Token");
    // testnetERC20TokenContract = await testnetERC20TokenFactory.deploy("TestToken", "TT", 18);
    const tokens = getTokens("hardhat");
    const tokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    erc20TestToken = TestnetERC20TokenFactory.connect(
      tokenAddress,
      owner
    );

    const nonce = await deployWallet.getTransactionCount(); 

    await startInitializeChain(deployer, deployWallet, chainId, nonce, gasPrice);
    
    const l1ERC20BridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1ERC20Bridge").abi);
    const upgradeCall =  l1ERC20BridgeInterface.encodeFunctionData(
      "initializeChainGovernance(uint256,address,address)",  
      [chainId, ADDRESS_ONE, ADDRESS_ONE]);

    await executeUpgrade(deployer,deployWallet, l1ERC20Bridge.address, 0, upgradeCall);

    await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits("10000", 18));
    await erc20TestToken.connect(randomSigner).approve(l1ERC20BridgeAddress, ethers.utils.parseUnits("10000", 18));
  });

  it("Check startInitializeChain", async () => {
    const txHash = await l1ERC20BridgeInit.bridgeImplDeployOnL2TxHash(chainId);

    expect(txHash).not.equal(ethers.constants.HashZero);
  })

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
    expect(revertReason).equal("pm");
  });

  it("Should revert on finalizing a withdrawal with wrong function signature", async () => {
    const revertReason = await getCallRevertReason(
      l1ERC20Bridge
        .connect(randomSigner)
        .finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(76), [ethers.constants.HashZero])
    );
    expect(revertReason).equal("Incorrect message function selector");
  });

  it("Should revert on finalizing a withdrawal with wrong batch number", async () => {
    const functionSignature = "0xc87325f1";
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
    const functionSignature = "0xc87325f1";
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
    const functionSignature = "0xc87325f1";
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
    expect(revertReason).equal("nq");
  });
});

async function depositERC20(
  bridge: IL1Bridge,
  zksyncContract: IBridgehub,
  chainId: string,
  l2Receiver: string,
  l1Token: string,
  amount: ethers.BigNumber,
  l2GasLimit: number,
  l2RefundRecipient = ethers.constants.AddressZero
) {
  const gasPrice = await bridge.provider.getGasPrice();
  const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
  const neededValue = await zksyncContract.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata);

  await bridge.deposit(
    chainId,
    l2Receiver,
    l1Token,
    neededValue,
    amount,
    l2GasLimit,
    REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
    l2RefundRecipient,
    {
      value: neededValue,
    }
  );
}
