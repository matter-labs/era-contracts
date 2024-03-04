import { expect } from "chai";
import * as ethers from "ethers";
import { Wallet } from "ethers";
import * as hardhat from "hardhat";

import type { GettersFacet, MockExecutorFacet } from "../../typechain";
import { Interface } from "ethers/lib/utils";

import { MailboxFacetFactory, GettersFacetFactory, MockExecutorFacetFactory } from "../../typechain";
import type { IMailbox } from "../../typechain/IMailbox";

import { initialTestnetDeploymentProcess } from "../../src.ts/deploy-test-process";
import { Action, facetCut } from "../../src.ts/diamondCut";
import { getTokens } from "../../src.ts/deploy-token";
import { ethTestConfig } from "../../src.ts/utils";

import {
  L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
  L2_TO_L1_MESSENGER,
  getCallRevertReason,
  requestExecuteDirect,
} from "./utils";

describe("Mailbox Era's legacy functions tests", function () {
  let mailbox: IMailbox;
  let getter: GettersFacet;
  let proxyAsMockExecutor: MockExecutorFacet;
  let owner: ethers.Signer;
  const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
  const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;

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

    process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID = (9).toString();
    const deployer = await initialTestnetDeploymentProcess(deployWallet, ownerAddress, gasPrice, [extraFacet]);
    // we want to reset the original for the rest of the tests (including test files)
    process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID = (270).toString();

    // The L1SharedBridge is compiled with the ERA_DIAMOND_PROXY address in hardhat config, so we update the shared bridge
    // because all the varaibles are already set in the proxy, this is upgrade works.
    const sharedBridgeTestFactory = await hardhat.ethers.getContractFactory("L1SharedBridgeTest");
    const tokens = getTokens();
    const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    const sharedBridgeTest = await sharedBridgeTestFactory.deploy(
      deployer.addresses.StateTransition.DiamondProxy,
      l1WethToken,
      deployer.addresses.Bridgehub.BridgehubProxy,
      deployer.addresses.Bridges.ERC20BridgeProxy
    );

    const proxyAdminInterface = new Interface(hardhat.artifacts.readArtifactSync("ProxyAdmin").abi);
    const calldata = proxyAdminInterface.encodeFunctionData("upgrade(address,address)", [
      deployer.addresses.Bridges.SharedBridgeProxy,
      sharedBridgeTest.address,
    ]);

    await deployer.executeUpgrade(deployer.addresses.TransparentProxyAdmin, 0, calldata);
    if (deployer.verbose) {
      console.log("L1SharedBridge upgrade sent for testing");
    }

    mailbox = MailboxFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);
    getter = GettersFacetFactory.connect(deployer.addresses.StateTransition.DiamondProxy, deployWallet);

    proxyAsMockExecutor = MockExecutorFacetFactory.connect(
      deployer.addresses.StateTransition.DiamondProxy,
      mockExecutorContract.signer
    );
  });

  /// we have this here as calling through the bridgehub does not work
  it("Should not accept bytecode that is too long", async () => {
    const revertReason = await getCallRevertReason(
      requestExecuteDirect(
        mailbox,
        ethers.constants.AddressZero,
        ethers.BigNumber.from(0),
        "0x",
        ethers.BigNumber.from(100000),
        [
          // "+64" to keep the length in words odd and bytecode chunkable
          new Uint8Array(MAX_CODE_LEN_BYTES + 64),
        ],
        ethers.constants.AddressZero
      )
    );

    expect(revertReason).equal("pp");
  });

  describe("finalizeEthWithdrawal", function () {
    const BLOCK_NUMBER = 0;
    const MESSAGE_INDEX = 0;
    const TX_NUMBER_IN_BLOCK = 0;
    const L1_RECEIVER = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
    const AMOUNT = 1;

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
      expect(revertReason).equal("ShB withd w proof");
    });

    it("Successful deposit", async () => {
      const priorityQueueLengthBefore = await getter.getPriorityQueueSize();
      const amount = ethers.utils.parseEther("1");
      await requestExecuteDirect(
        mailbox,
        ethers.constants.AddressZero,
        ethers.BigNumber.from(2000000),
        "0x",
        ethers.BigNumber.from(1000000),
        [],
        ethers.constants.AddressZero,
        amount
      );
      const priorityQueueLengthAfter = await getter.getPriorityQueueSize();
      expect(priorityQueueLengthAfter.sub(priorityQueueLengthBefore)).equal(1);
    });

    it("Successful withdrawal", async () => {
      const balanceBefore = await hardhat.ethers.provider.getBalance(L1_RECEIVER);

      await mailbox.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF);
      const balanceAfter = await hardhat.ethers.provider.getBalance(L1_RECEIVER);
      expect(balanceAfter.sub(balanceBefore)).equal(AMOUNT);
    });

    it("Reverts when withdrawal is already finalized", async () => {
      const revertReason = await getCallRevertReason(
        mailbox.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF)
      );
      expect(revertReason).equal("Withdrawal is already finalized");
    });
  });
});
