import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import * as hardhat from "hardhat";

import * as fs from "fs";

import { IBridgehubMailbox } from "../../typechain/IBridgehubMailbox";
import { AllowList, L1WethBridge, L1WethBridgeFactory, WETH9, WETH9Factory } from "../../typechain";
import { AccessMode, getCallRevertReason, initialDeployment, CONTRACTS_LATEST_PROTOCOL_VERSION } from "./utils";
import { hashL2Bytecode } from "../../scripts/utils";
import {
  calculateWethAddresses,
  L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
  L2_WETH_BRIDGE_PROXY_BYTECODE,
} from "../../scripts/utils-bytecode";

import { Interface } from "ethers/lib/utils";
import { Address } from "zksync-web3/build/src/types";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

export async function create2DeployFromL1(
  bridgehub: IBridgehubMailbox,
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
  let allowList: AllowList;
  let bridgeProxy: L1WethBridge;
  let l1Weth: WETH9;
  let functionSignature = "0x0fdef251";
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

    let deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, []);

    chainId = deployer.chainId;
    allowList = deployer.l1AllowList(deployWallet);

    l1Weth = WETH9Factory.connect((await (await hardhat.ethers.getContractFactory("WETH9")).deploy()).address, owner);

    // prepare the bridge

    const bridge = await (
      await hardhat.ethers.getContractFactory("L1WethBridge")
    ).deploy(l1Weth.address, deployer.addresses.Bridgehub.BridgehubProxy, deployer.addresses.AllowList);

    const _bridgeProxy = await (await hardhat.ethers.getContractFactory("ERC1967Proxy")).deploy(bridge.address, "0x");

    bridgeProxy = L1WethBridgeFactory.connect(_bridgeProxy.address, _bridgeProxy.signer);

    const { l2WethProxyAddress, l2WethBridgeProxyAddress } = calculateWethAddresses(
      await owner.getAddress(),
      bridgeProxy.address,
      l1Weth.address
    );

    await bridgeProxy.initialize(
      [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
      l2WethProxyAddress,
      l2WethBridgeProxyAddress,
      await owner.getAddress()
    );

    await bridgeProxy.initializeChain(
      chainId,
      [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
      ethers.constants.WeiPerEther,
      ethers.constants.WeiPerEther,
      { value: ethers.constants.WeiPerEther.mul(2) }
    );
  });

  it("Should not allow an un-whitelisted address to deposit", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .deposit(
          chainId,
          await randomSigner.getAddress(),
          ethers.constants.AddressZero,
          0,
          0,
          0,
          ethers.constants.AddressZero
        )
    );

    expect(revertReason).equal("nr");

    // This is only so the following tests don't need whitelisting
    await (await allowList.setAccessMode(bridgeProxy.address, AccessMode.Public)).wait();
  });

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
          ethers.constants.AddressZero
        )
    );

    expect(revertReason).equal("Amount cannot be zero");
  });

  it(`Should deposit successfully`, async () => {
    await l1Weth.connect(randomSigner).deposit({ value: 100 });
    await (await l1Weth.connect(randomSigner).approve(bridgeProxy.address, 100)).wait();
    await bridgeProxy
      .connect(randomSigner)
      .deposit(
        chainId,
        await randomSigner.getAddress(),
        l1Weth.address,
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
    expect(revertReason).equal("pm");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("is");
  });

  it("Should revert on finalizing a withdrawal with wrong receiver", async () => {
    const revertReason = await getCallRevertReason(
      bridgeProxy
        .connect(randomSigner)
        .finalizeWithdrawal(
          chainId,
          0,
          0,
          0,
          ethers.utils.hexConcat([functionSignature, ethers.utils.randomBytes(92)]),
          [ethers.constants.HashZero]
        )
    );
    expect(revertReason).equal("pi");
  });

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
    expect(revertReason).equal("pi");
  });
});
