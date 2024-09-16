// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER, SYSTEM_CONFIG } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { initialBridgehubDeployment } from "../src.ts/deploy-process";
import {
  ethTestConfig,
  getAddressFromEnv,
  getNumberFromEnv,
  ADDRESS_ONE,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMaxGasLimit,
  L2_BRIDGEHUB_ADDRESS,
  computeL2Create2Address,
  DIAMOND_CUT_DATA_ABI_STRING,
} from "../src.ts/utils";

import { Wallet as ZkWallet, Provider as ZkProvider, utils as zkUtils } from "zksync-ethers";
import { IChainTypeManagerFactory } from "../typechain/IChainTypeManagerFactory";
import { IDiamondInitFactory } from "../typechain/IDiamondInitFactory";
import { TestnetERC20TokenFactory } from "../typechain/TestnetERC20TokenFactory";
import { BOOTLOADER_FORMAL_ADDRESS } from "zksync-ethers/build/utils";

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy").description("deploy L1 contracts");

  program
    .command("compute-migrated-chain-address")
    .requiredOption("--chain-id <chain-id>")
    .option("--private-key <private-key>")
    .action(async (cmd) => {
      if (process.env.CONTRACTS_BASE_NETWORK_ZKSYNC !== "true") {
        throw new Error("This script is only for zkSync network");
      }

      const provider = new ZkProvider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const ethProvider = new ethers.providers.JsonRpcProvider(process.env.ETH_CLIENT_WEB3_URL);
      const deployWallet = cmd.privateKey
        ? new ZkWallet(cmd.privateKey, provider)
        : (ZkWallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider) as ethers.Wallet | ZkWallet);

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        verbose: true,
      });

      deployer.addresses.StateTransition.AdminFacet = getAddressFromEnv("GATEWAY_ADMIN_FACET_ADDR");
      deployer.addresses.StateTransition.MailboxFacet = getAddressFromEnv("GATEWAY_MAILBOX_FACET_ADDR");
      deployer.addresses.StateTransition.ExecutorFacet = getAddressFromEnv("GATEWAY_EXECUTOR_FACET_ADDR");
      deployer.addresses.StateTransition.GettersFacet = getAddressFromEnv("GATEWAY_GETTERS_FACET_ADDR");
      deployer.addresses.StateTransition.DiamondInit = getAddressFromEnv("GATEWAY_DIAMOND_INIT_ADDR");
      deployer.addresses.StateTransition.Verifier = getAddressFromEnv("GATEWAY_VERIFIER_ADDR");
      deployer.addresses.BlobVersionedHashRetriever = getAddressFromEnv("GATEWAY_BLOB_VERSIONED_HASH_RETRIEVER_ADDR");
      deployer.addresses.ValidatorTimeLock = getAddressFromEnv("GATEWAY_VALIDATOR_TIMELOCK_ADDR");
      deployer.addresses.Bridges.SharedBridgeProxy = getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR");
      deployer.addresses.StateTransition.StateTransitionProxy = getAddressFromEnv(
        "GATEWAY_STATE_TRANSITION_PROXY_ADDR"
      );

      const stm = deployer.chainTypeManagerContract(provider);
      const bridgehub = deployer.bridgehubContract(ethProvider);
      const diamondInit = IDiamondInitFactory.connect(deployer.addresses.StateTransition.DiamondInit, provider);
      const bytes32 = (x: ethers.BigNumberish) => ethers.utils.hexZeroPad(ethers.utils.hexlify(x), 32);

      const diamondCut = await deployer.initialZkSyncZKChainDiamondCut([], true);
      const mandatoryInitData = [
        diamondInit.interface.getSighash("initialize"),
        bytes32(parseInt(cmd.chainId)),
        bytes32(getAddressFromEnv("GATEWAY_BRIDGEHUB_PROXY_ADDR")),
        bytes32(deployer.addresses.StateTransition.StateTransitionProxy),
        bytes32(await stm.protocolVersion()),
        bytes32(deployer.deployWallet.address),
        bytes32(deployer.addresses.ValidatorTimeLock),
        await bridgehub.baseTokenAssetId(cmd.chainId),
        bytes32(deployer.addresses.Bridges.SharedBridgeProxy),
        await stm.storedBatchZero(),
      ];

      diamondCut.initCalldata = ethers.utils.hexConcat([...mandatoryInitData, diamondCut.initCalldata]);
      const bytecode = hardhat.artifacts.readArtifactSync("DiamondProxy").bytecode;
      const gatewayChainId = (await provider.getNetwork()).chainId;
      const constructorData = new ethers.utils.AbiCoder().encode(
        ["uint256", DIAMOND_CUT_DATA_ABI_STRING],
        [gatewayChainId, diamondCut]
      );

      const address = computeL2Create2Address(
        deployer.addresses.StateTransition.StateTransitionProxy,
        bytecode,
        constructorData,
        ethers.constants.HashZero
      );

      console.log(address);
    });

  program
    .command("deploy-sync-layer-contracts")
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      if (process.env.CONTRACTS_BASE_NETWORK_ZKSYNC !== "true") {
        throw new Error("This script is only for zkSync network");
      }

      const provider = new ZkProvider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const deployWallet = cmd.privateKey
        ? new ZkWallet(cmd.privateKey, provider)
        : (ZkWallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider) as ethers.Wallet | ZkWallet);

      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      console.log(`Using owner address: ${ownerAddress}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const create2Salt = cmd.create2Salt ? cmd.create2Salt : ethers.utils.hexlify(ethers.utils.randomBytes(32));

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      if (deployer.isZkMode()) {
        console.log("Deploying on a zkSync network!");
      }
      deployer.addresses.Bridges.SharedBridgeProxy = getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR");

      await initialBridgehubDeployment(deployer, [], gasPrice, true, create2Salt);
      await initialBridgehubDeployment(deployer, [], gasPrice, false, create2Salt);
    });

  program
    .command("register-sync-layer")
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      // Now, all the operations are done on L1
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      console.log(`Using owner address: ${ownerAddress}`);
      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });
      await registerSLContractsOnL1(deployer);
    });

  program
    .command("migrate-to-sync-layer")
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      console.log("Starting migration of the current chain to sync layer");

      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      const gatewayChainId = getNumberFromEnv("GATEWAY_CHAIN_ID");
      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);

      const currentChainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");

      const ctm = deployer.chainTypeManagerContract(deployer.deployWallet);

      const counterPart = getAddressFromEnv("GATEWAY_STATE_TRANSITION_PROXY_ADDR");

      // FIXME: do it more gracefully
      deployer.addresses.StateTransition.AdminFacet = getAddressFromEnv("GATEWAY_ADMIN_FACET_ADDR");
      deployer.addresses.StateTransition.MailboxFacet = getAddressFromEnv("GATEWAY_MAILBOX_FACET_ADDR");
      deployer.addresses.StateTransition.ExecutorFacet = getAddressFromEnv("GATEWAY_EXECUTOR_FACET_ADDR");
      deployer.addresses.StateTransition.GettersFacet = getAddressFromEnv("GATEWAY_GETTERS_FACET_ADDR");
      deployer.addresses.StateTransition.Verifier = getAddressFromEnv("GATEWAY_VERIFIER_ADDR");
      deployer.addresses.BlobVersionedHashRetriever = getAddressFromEnv("GATEWAY_BLOB_VERSIONED_HASH_RETRIEVER_ADDR");
      deployer.addresses.StateTransition.DiamondInit = getAddressFromEnv("GATEWAY_DIAMOND_INIT_ADDR");

      const receipt = await deployer.moveChainToGateway(gatewayChainId, gasPrice);

      const gatewayAddress = await ctm.getZKChain(gatewayChainId);

      const l2TxHash = zkUtils.getL2HashFromPriorityOp(receipt, gatewayAddress);

      console.log("Hash of the transaction on SL chain: ", l2TxHash);

      const gatewayProvider = new ZkProvider(process.env.GATEWAY_API_WEB3_JSON_RPC_HTTP_URL);

      const txL2Handle = gatewayProvider.getL2TransactionFromPriorityOp(
        await deployWallet.provider.getTransaction(receipt.transactionHash)
      );

      const receiptOnSL = await (await txL2Handle).wait();
      console.log("Finalized on SL with hash:", receiptOnSL.transactionHash);

      const ctmOnSL = IChainTypeManagerFactory.connect(counterPart, gatewayProvider);
      const zkChainAddress = await ctmOnSL.getZKChain(currentChainId);
      console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${zkChainAddress}`);

      console.log("Success!");
    });

  program
    .command("recover-from-failed-migration")
    .option("--private-key <private-key>")
    .option("--failed-tx-l2-hash <failed-tx-l2-hash>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      const gatewayChainId = getNumberFromEnv("GATEWAY_CHAIN_ID");
      const gatewayProvider = new ZkProvider(process.env.GATEWAY_API_WEB3_JSON_RPC_HTTP_URL);
      console.log("Obtaining proof...");
      const proof = await getTxFailureProof(gatewayProvider, cmd.failedTxL2Hash);

      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(deployWallet.address);
      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      const zkChain = deployer.stateTransitionContract(deployer.deployWallet);

      console.log(await zkChain.getAdmin());

      console.log("Executing recovery...");

      await (
        await zkChain.recoverFromFailedMigrationToGateway(
          gatewayChainId,
          proof.l2BatchNumber,
          proof.l2MessageIndex,
          proof.l2TxNumberInBatch,
          proof.merkleProof
        )
      ).wait();

      console.log("Success!");
    });

  program
    .command("prepare-validators")
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      const gatewayProvider = new ZkProvider(process.env.GATEWAY_API_WEB3_JSON_RPC_HTTP_URL);
      const currentChainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");

      // Right now the new admin is the wallet itself.
      const adminWallet = cmd.privateKey
        ? new ZkWallet(cmd.privateKey, gatewayProvider)
        : ZkWallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(gatewayProvider);

      const operators = [
        process.env.ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR,
        process.env.ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR,
      ];

      const deployer = new Deployer({
        deployWallet: adminWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress: adminWallet.address,
        verbose: true,
      });

      console.log("Enabling validators");

      // FIXME: do it in cleaner way
      deployer.addresses.ValidatorTimeLock = getAddressFromEnv("GATEWAY_VALIDATOR_TIMELOCK_ADDR");
      const timelock = deployer.validatorTimelock(deployer.deployWallet);

      for (const operator of operators) {
        if (await timelock.validators(currentChainId, operator)) {
          continue;
        }

        await deployer.deployWallet.sendTransaction({
          to: operator,
          value: ethers.utils.parseEther("5"),
        });

        await (await timelock.addValidator(currentChainId, operator)).wait();
      }

      // FIXME: this method includes bridgehub manipulation, but in the future it won't.
      deployer.addresses.StateTransition.StateTransitionProxy = getAddressFromEnv(
        "GATEWAY_STATE_TRANSITION_PROXY_ADDR"
      );
      deployer.addresses.Bridgehub.BridgehubProxy = getAddressFromEnv("GATEWAY_BRIDGEHUB_PROXY_ADDR");

      const zkChain = deployer.stateTransitionContract(deployer.deployWallet);

      console.log("Setting SL DA validators");
      // This logic should be distinctive between Validium and Rollup
      const l1DaValidator = getAddressFromEnv("GATEWAY_L1_RELAYED_SL_DA_VALIDATOR");
      const l2DaValidator = getAddressFromEnv("CONTRACTS_L2_DA_VALIDATOR_ADDR");
      await (await zkChain.setDAValidatorPair(l1DaValidator, l2DaValidator)).wait();

      console.log("Success!");
    });

  await program.parseAsync(process.argv);
}

async function registerSLContractsOnL1(deployer: Deployer) {
  /// CTM asset info
  /// l2Bridgehub in L1Bridghub

  const chainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");

  console.log(`Gateway chain Id: ${chainId}`);

  const l1Bridgehub = deployer.bridgehubContract(deployer.deployWallet);
  const l1CTM = deployer.chainTypeManagerContract(deployer.deployWallet);
  console.log(deployer.addresses.StateTransition.StateTransitionProxy);
  const gatewayAddress = await l1Bridgehub.getZKChain(chainId);
  // this script only works when owner is the deployer
  console.log("Registering Gateway chain id on the CTM");
  const receipt1 = await deployer.executeUpgrade(
    l1Bridgehub.address,
    0,
    l1Bridgehub.interface.encodeFunctionData("registerSettlementLayer", [chainId, true])
  );

  console.log("Registering Gateway as settlement layer on the L1", receipt1.transactionHash);

  const gasPrice = (await deployer.deployWallet.provider.getGasPrice()).mul(GAS_MULTIPLIER);
  const value = (
    await l1Bridgehub.l2TransactionBaseCost(chainId, gasPrice, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA)
  ).mul(10);
  const baseTokenAddress = await l1Bridgehub.baseToken(chainId);
  const ethIsBaseToken = baseTokenAddress == ADDRESS_ONE;
  if (!ethIsBaseToken) {
    const baseToken = TestnetERC20TokenFactory.connect(baseTokenAddress, this.deployWallet);
    await (await baseToken.transfer(this.addresses.Governance, value)).wait();
    await this.executeUpgrade(
      baseTokenAddress,
      0,
      baseToken.interface.encodeFunctionData("approve", [this.addresses.Bridges.SharedBridgeProxy, value.mul(2)])
    );
  }
  const ctmDeploymentTracker = deployer.ctmDeploymentTracker(deployer.deployWallet);
  const assetRouter = deployer.defaultSharedBridge(deployer.deployWallet);
  const assetId = await l1Bridgehub.ctmAssetIdFromChainId(chainId);

  // Setting the L2 bridgehub as the counterpart for the CTM asset
  const receipt2 = await deployer.executeUpgrade(
    l1Bridgehub.address,
    ethIsBaseToken ? value : 0,
    l1Bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
      {
        chainId,
        mintValue: value,
        l2Value: 0,
        l2GasLimit: priorityTxMaxGasLimit,
        l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
        refundRecipient: deployer.deployWallet.address,
        secondBridgeAddress: assetRouter.address,
        secondBridgeValue: 0,
        secondBridgeCalldata:
          "0x02" +
          ethers.utils.defaultAbiCoder.encode(["bytes32", "address"], [assetId, L2_BRIDGEHUB_ADDRESS]).slice(2),
      },
    ])
  );
  const l2TxHash = zkUtils.getL2HashFromPriorityOp(receipt2, gatewayAddress);
  console.log("CTM asset registered in L2SharedBridge on SL tx hash: ", receipt2.transactionHash);
  console.log("CTM asset registered in L2SharedBridge on SL l2 tx hash: ", l2TxHash);

  const l2CTMAddress = getAddressFromEnv("GATEWAY_STATE_TRANSITION_PROXY_ADDR");

  // Whitelisting the CTM address on L2
  const receipt3 = await deployer.executeUpgradeOnL2(
    chainId,
    L2_BRIDGEHUB_ADDRESS,
    gasPrice,
    l1Bridgehub.interface.encodeFunctionData("addChainTypeManager", [l2CTMAddress]),
    priorityTxMaxGasLimit
  );
  const l2TxHash2dot5 = zkUtils.getL2HashFromPriorityOp(receipt3, gatewayAddress);
  console.log(`L2 CTM ,l2 txHash: ${l2TxHash2dot5}`);
  console.log(`L2 CTM address ${l2CTMAddress} registered on gateway, txHash: ${receipt3.transactionHash}`);

  // Setting the corresponding CTM address on L2.
  const receipt4 = await deployer.executeUpgrade(
    l1Bridgehub.address,
    value,
    l1Bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
      {
        chainId,
        mintValue: value,
        l2Value: 0,
        l2GasLimit: priorityTxMaxGasLimit,
        l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
        refundRecipient: deployer.deployWallet.address,
        secondBridgeAddress: ctmDeploymentTracker.address,
        secondBridgeValue: 0,
        secondBridgeCalldata:
          "0x01" + ethers.utils.defaultAbiCoder.encode(["address", "address"], [l1CTM.address, l2CTMAddress]).slice(2),
      },
    ])
  );
  const l2TxHash3 = zkUtils.getL2HashFromPriorityOp(receipt4, gatewayAddress);
  console.log("CTM asset registered in L2 Bridgehub on SL", receipt4.transactionHash);
  console.log("CTM asset registered in L2 Bridgehub on SL l2TxHash", l2TxHash3);
}

// TODO: maybe move it to SDK
async function getTxFailureProof(provider: ZkProvider, l2TxHash: string) {
  const receipt = await provider.getTransactionReceipt(ethers.utils.hexlify(l2TxHash));
  const successL2ToL1LogIndex = receipt.l2ToL1Logs.findIndex(
    (l2ToL1log) => l2ToL1log.sender == BOOTLOADER_FORMAL_ADDRESS && l2ToL1log.key == l2TxHash
  );
  const successL2ToL1Log = receipt.l2ToL1Logs[successL2ToL1LogIndex];
  if (successL2ToL1Log.value != ethers.constants.HashZero) {
    throw new Error("The tx was successful");
  }

  const proof = await provider.getLogProof(l2TxHash, successL2ToL1LogIndex);
  return {
    l2BatchNumber: receipt.l1BatchNumber,
    l2MessageIndex: proof.id,
    l2TxNumberInBatch: receipt.l1BatchTxIndex,
    merkleProof: proof.proof,
  };
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
