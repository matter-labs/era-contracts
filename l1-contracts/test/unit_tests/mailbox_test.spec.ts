import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { Bridgehub, Forwarder, MailboxFacetTest, MockExecutorFacet } from "../../typechain";
import {
  BridgehubFactory,
  ForwarderFactory,
  MailboxFacetFactory,
  MailboxFacetTestFactory,
  MockExecutorFacetFactory,
} from "../../typechain";
import type { IMailbox } from "../../typechain/IMailbox";

import { PubdataPricingMode, ethTestConfig } from "../../src.ts/utils";
import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { Action, facetCut } from "../../src.ts/diamondCut";

import {
  DEFAULT_REVERT_REASON,
  L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
  L2_TO_L1_MESSENGER,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  defaultFeeParams,
  getCallRevertReason,
  requestExecute,
} from "./utils";

describe("Mailbox tests", function () {
  let mailbox: IMailbox;
  let proxyAsMockExecutor: MockExecutorFacet;
  let bridgehub: Bridgehub;
  let owner: ethers.Signer;
  let forwarder: Forwarder;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 271;

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

    const mockExecutorFactory = await hardhat.ethers.getContractFactory("MockExecutorFacet");
    const mockExecutorContract = await mockExecutorFactory.deploy();
    const extraFacet = facetCut(mockExecutorContract.address, mockExecutorContract.interface, Action.Add, true);

    const deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [extraFacet]);

    chainId = deployer.chainId;

    bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);
    mailbox = MailboxFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);

    proxyAsMockExecutor = MockExecutorFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
      mockExecutorContract.signer
    );

    const forwarderFactory = await hardhat.ethers.getContractFactory("Forwarder");
    const forwarderContract = await forwarderFactory.deploy();
    forwarder = ForwarderFactory.connect(forwarderContract.address, forwarderContract.signer);
  });

  it("Should accept correctly formatted bytecode", async () => {
    const revertReason = await getCallRevertReason(
      requestExecute(
        chainId,
        bridgehub,
        ethers.constants.AddressZero,
        ethers.BigNumber.from(0),
        "0x",
        ethers.BigNumber.from(1000000),
        [new Uint8Array(32)],
        ethers.constants.AddressZero
      )
    );
    expect(revertReason).equal(DEFAULT_REVERT_REASON);
  });

  it("Should not accept bytecode is not chunkable", async () => {
    const revertReason = await getCallRevertReason(
      requestExecute(
        chainId,
        bridgehub,
        ethers.constants.AddressZero,
        ethers.BigNumber.from(0),
        "0x",
        ethers.BigNumber.from(100000),
        [new Uint8Array(63)],
        ethers.constants.AddressZero
      )
    );

    expect(revertReason).equal("pq");
  });

  it("Should not accept bytecode of even length in words", async () => {
    const revertReason = await getCallRevertReason(
      requestExecute(
        chainId,
        bridgehub,
        ethers.constants.AddressZero,
        ethers.BigNumber.from(0),
        "0x",
        ethers.BigNumber.from(100000),
        [new Uint8Array(64)],
        ethers.constants.AddressZero
      )
    );

    expect(revertReason).equal("ps");
  });

  describe("finalizeEthWithdrawal", function () {
    const BLOCK_NUMBER = 0;
    const MESSAGE_INDEX = 0;
    const TX_NUMBER_IN_BLOCK = 0;

    const MESSAGE =
      "0x6c0960f9d8dA6BF26964aF9D7eEd9e03E53415D37aA960450000000000000000000000000000000000000000000000000000000000000001";
    const MESSAGE_HASH = ethers.utils.keccak256(MESSAGE);
    const key = ethers.utils.hexZeroPad(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, 32);
    const HASHED_LOG = ethers.utils.solidityKeccak256(
      ["uint8", "bool", "uint16", "address", "bytes32", "bytes32"],
      [0, true, TX_NUMBER_IN_BLOCK, L2_TO_L1_MESSENGER, key, MESSAGE_HASH]
    );

    const MERKLE_PROOF = [
      "0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba",
      "0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0",
      "0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111",
      "0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa",
      "0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89",
      "0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272",
      "0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d",
      "0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c",
      "0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db",
    ];

    let L2_LOGS_TREE_ROOT = HASHED_LOG;
    for (let i = 0; i < MERKLE_PROOF.length; i++) {
      L2_LOGS_TREE_ROOT = ethers.utils.keccak256(L2_LOGS_TREE_ROOT + MERKLE_PROOF[i].slice(2));
    }

    before(async () => {
      await proxyAsMockExecutor.saveL2LogsRootHash(BLOCK_NUMBER, L2_LOGS_TREE_ROOT);
    });

    it("Reverts when proof is invalid", async () => {
      const invalidProof = [...MERKLE_PROOF];
      invalidProof[0] = "0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43bb";

      const revertReason = await getCallRevertReason(
        mailbox.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, invalidProof)
      );
      expect(revertReason).equal("Mailbox: finalizeEthWithdrawal only available for Era on mailbox");
    });

    it("Successful withdrawal", async () => {
      const revertReason = await getCallRevertReason(
        mailbox.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF)
      );
      expect(revertReason).equal("Mailbox: finalizeEthWithdrawal only available for Era on mailbox");
    });

    it("Reverts when withdrawal is already finalized", async () => {
      const revertReason = await getCallRevertReason(
        mailbox.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF)
      );
      expect(revertReason).equal("Mailbox: finalizeEthWithdrawal only available for Era on mailbox");
    });
  });

  describe("L2 gas price", async () => {
    let testContract: MailboxFacetTest;
    const TEST_GAS_PRICES = [];

    async function testOnAllGasPrices(
      testFunc: (price: ethers.BigNumber) => ethers.utils.Deferrable<ethers.BigNumber>
    ) {
      for (const gasPrice of TEST_GAS_PRICES) {
        expect(await testContract.getL2GasPrice(gasPrice)).to.eq(testFunc(gasPrice));
      }
    }

    before(async () => {
      const mailboxTestContractFactory = await hardhat.ethers.getContractFactory("MailboxFacetTest");
      const mailboxTestContract = await mailboxTestContractFactory.deploy(chainId);
      testContract = MailboxFacetTestFactory.connect(mailboxTestContract.address, mailboxTestContract.signer);

      // Generating 10 more gas prices for test suit
      let priceGwei = 0.001;
      while (priceGwei < 10000) {
        priceGwei *= 2;
        const priceWei = ethers.utils.parseUnits(priceGwei.toString(), "gwei");
        TEST_GAS_PRICES.push(priceWei);
      }
    });

    it("Should allow simulating old behaviour", async () => {
      // Simulating old L2 gas price calculations might be helpful for migration between the systems
      await (
        await testContract.setFeeParams({
          ...defaultFeeParams(),
          pubdataPricingMode: PubdataPricingMode.Rollup,
          batchOverheadL1Gas: 0,
          minimalL2GasPrice: 500_000_000,
        })
      ).wait();

      // Testing the logic under low / medium / high L1 gas price
      testOnAllGasPrices(expectedLegacyL2GasPrice);
    });

    it("Should allow free pubdata", async () => {
      await (
        await testContract.setFeeParams({
          ...defaultFeeParams(),
          pubdataPricingMode: PubdataPricingMode.Validium,
          batchOverheadL1Gas: 0,
        })
      ).wait();

      // The gas price per pubdata is still constant, however, the L2 gas price is always equal to the minimalL2GasPrice
      testOnAllGasPrices(() => {
        return ethers.BigNumber.from(defaultFeeParams().minimalL2GasPrice);
      });
    });

    it("Should work fine in general case", async () => {
      await (
        await testContract.setFeeParams({
          ...defaultFeeParams(),
        })
      ).wait();

      testOnAllGasPrices(calculateL2GasPrice);
    });
  });

  let callDirectly, callViaForwarder, callViaConstructorForwarder;

  before(async () => {
    const l2GasLimit = ethers.BigNumber.from(10000000);

    callDirectly = async (refundRecipient) => {
      return {
        transaction: await requestExecute(
          chainId,
          bridgehub.connect(owner),
          ethers.constants.AddressZero,
          ethers.BigNumber.from(0),
          "0x",
          l2GasLimit,
          [new Uint8Array(32)],
          refundRecipient
        ),
        expectedSender: await owner.getAddress(),
      };
    };

    const overrides: ethers.PayableOverrides = {};
    overrides.gasPrice = await bridgehub.provider.getGasPrice();
    overrides.value = await bridgehub.l2TransactionBaseCost(
      chainId,
      overrides.gasPrice,
      l2GasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    const mintValue = await overrides.value;
    overrides.gasLimit = 10000000;

    const encodeRequest = (refundRecipient) =>
      bridgehub.interface.encodeFunctionData("requestL2TransactionDirect", [
        {
          chainId,
          l2Contract: ethers.constants.AddressZero,
          mintValue: mintValue,
          l2Value: 0,
          l2Calldata: "0x",
          l2GasLimit,
          l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
          factoryDeps: [new Uint8Array(32)],
          refundRecipient,
        },
      ]);

    callViaForwarder = async (refundRecipient) => {
      return {
        transaction: await forwarder.forward(bridgehub.address, await encodeRequest(refundRecipient), overrides),
        expectedSender: aliasAddress(forwarder.address),
      };
    };

    callViaConstructorForwarder = async (refundRecipient) => {
      const constructorForwarder = await (
        await hardhat.ethers.getContractFactory("ConstructorForwarder")
      ).deploy(bridgehub.address, encodeRequest(refundRecipient), overrides);

      return {
        transaction: constructorForwarder.deployTransaction,
        expectedSender: aliasAddress(constructorForwarder.address),
      };
    };
  });

  it("Should only alias externally-owned addresses", async () => {
    const indirections = [callDirectly, callViaForwarder, callViaConstructorForwarder];
    const refundRecipients = [
      [bridgehub.address, false],
      [await bridgehub.signer.getAddress(), true],
    ];

    for (const sendTransaction of indirections) {
      for (const [refundRecipient, externallyOwned] of refundRecipients) {
        const result = await sendTransaction(refundRecipient);

        const [, event2] = (await result.transaction.wait()).logs;
        const parsedEvent = mailbox.interface.parseLog(event2);
        expect(parsedEvent.name).to.equal("NewPriorityRequest");

        const canonicalTransaction = parsedEvent.args.transaction;
        expect(canonicalTransaction.from).to.equal(result.expectedSender);

        expect(canonicalTransaction.reserved[1]).to.equal(
          externallyOwned ? refundRecipient : aliasAddress(refundRecipient)
        );
      }
    }
  });
});

function aliasAddress(address) {
  return ethers.BigNumber.from(address)
    .add("0x1111000000000000000000000000000000001111")
    .mask(20 * 8);
}

// Returns the expected L2 gas price to be used for an L1->L2 transaction
function calculateL2GasPrice(l1GasPrice: ethers.BigNumber) {
  const feeParams = defaultFeeParams();
  const gasPricePerPubdata = ethers.BigNumber.from(REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

  let pubdataPriceETH = ethers.BigNumber.from(0);
  if (feeParams.pubdataPricingMode === PubdataPricingMode.Rollup) {
    pubdataPriceETH = l1GasPrice.mul(17);
  }

  const batchOverheadETH = l1GasPrice.mul(feeParams.batchOverheadL1Gas);
  const fullPubdataPriceETH = pubdataPriceETH.add(batchOverheadETH.div(feeParams.maxPubdataPerBatch));

  const l2GasPrice = batchOverheadETH.div(feeParams.maxL2GasPerBatch).add(feeParams.minimalL2GasPrice);
  const minL2GasPriceETH = fullPubdataPriceETH.add(gasPricePerPubdata).sub(1).div(gasPricePerPubdata);

  if (l2GasPrice.gt(minL2GasPriceETH)) {
    return l2GasPrice;
  }

  return minL2GasPriceETH;
}

function expectedLegacyL2GasPrice(l1GasPrice: ethers.BigNumberish) {
  // In the previous release the following code was used to calculate the L2 gas price for L1->L2 transactions:
  //
  //  uint256 pubdataPriceETH = L1_GAS_PER_PUBDATA_BYTE * _l1GasPrice;
  //  uint256 minL2GasPriceETH = (pubdataPriceETH + _gasPerPubdata - 1) / _gasPerPubdata;
  //  return Math.max(FAIR_L2_GAS_PRICE, minL2GasPriceETH);
  //

  const pubdataPriceETH = ethers.BigNumber.from(l1GasPrice).mul(17);
  const gasPricePerPubdata = ethers.BigNumber.from(REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
  const FAIR_L2_GAS_PRICE = 500_000_000; // 0.5 gwei
  const minL2GasPriceETH = ethers.BigNumber.from(pubdataPriceETH.add(gasPricePerPubdata).sub(1)).div(
    gasPricePerPubdata
  );

  return ethers.BigNumber.from(Math.max(FAIR_L2_GAS_PRICE, minL2GasPriceETH.toNumber()));
}
