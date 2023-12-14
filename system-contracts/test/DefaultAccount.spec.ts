import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-web3";
import * as zksync from "zksync-web3";
import { serialize } from "zksync-web3/build/src/utils";
import type { Callable, DefaultAccount, DelegateCaller, L2EthToken, MockERC20Approve, NonceHolder } from "../typechain";
import { DefaultAccountFactory, L2EthTokenFactory, NonceHolderFactory } from "../typechain";
import {
  BOOTLOADER_FORMAL_ADDRESS,
  ETH_TOKEN_SYSTEM_CONTRACT_ADDRESS,
  NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { signedTxToTransactionData } from "./shared/transactions";
import { deployContract, getWallets, loadArtifact, setCode } from "./shared/utils";

describe("DefaultAccount tests", function () {
  let wallet: Wallet;
  let account: Wallet;
  let defaultAccount: DefaultAccount;
  let bootloader: ethers.Signer;
  let nonceHolder: NonceHolder;
  let l2EthToken: L2EthToken;
  let callable: Callable;
  let mockERC20Approve: MockERC20Approve;
  let paymasterFlowInterface: ethers.utils.Interface;
  let delegateCaller: DelegateCaller;

  const RANDOM_ADDRESS = ethers.utils.getAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");

  before(async () => {
    wallet = getWallets()[0];
    account = getWallets()[2];
    const defaultAccountArtifact = await loadArtifact("DefaultAccount");
    await setCode(account.address, defaultAccountArtifact.bytecode);
    defaultAccount = DefaultAccountFactory.connect(account.address, wallet);
    nonceHolder = NonceHolderFactory.connect(NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l2EthToken = L2EthTokenFactory.connect(ETH_TOKEN_SYSTEM_CONTRACT_ADDRESS, wallet);
    callable = (await deployContract("Callable")) as Callable;
    delegateCaller = (await deployContract("DelegateCaller")) as DelegateCaller;
    mockERC20Approve = (await deployContract("MockERC20Approve")) as MockERC20Approve;

    const paymasterFlowInterfaceArtifact = await loadArtifact("IPaymasterFlow");
    paymasterFlowInterface = new ethers.utils.Interface(paymasterFlowInterfaceArtifact.abi);

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [BOOTLOADER_FORMAL_ADDRESS],
    });
    bootloader = await ethers.getSigner(BOOTLOADER_FORMAL_ADDRESS);
  });

  after(async function () {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [BOOTLOADER_FORMAL_ADDRESS],
    });
  });

  describe("validateTransaction", function () {
    it("non-deployer ignored", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: RANDOM_ADDRESS,
        from: account.address,
        nonce: nonce,
        data: "0x",
        value: 0,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      const call = {
        from: wallet.address,
        to: defaultAccount.address,
        value: 0,
        data: defaultAccount.interface.encodeFunctionData("validateTransaction", [txHash, signedHash, txData]),
      };
      expect(await wallet.provider.call(call)).to.be.eq("0x");
    });

    it("invalid ignature", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: RANDOM_ADDRESS,
        from: account.address,
        nonce: nonce,
        data: "0x",
        value: 0,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      parsedTx.s = "0x0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0";
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      const call = {
        from: BOOTLOADER_FORMAL_ADDRESS,
        to: defaultAccount.address,
        value: 0,
        data: defaultAccount.interface.encodeFunctionData("validateTransaction", [txHash, signedHash, txData]),
      };
      expect(await bootloader.provider.call(call)).to.be.eq(ethers.constants.HashZero);
    });

    it("valid tx", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: RANDOM_ADDRESS,
        from: account.address,
        nonce: nonce,
        data: "0x",
        value: 0,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      const call = {
        from: BOOTLOADER_FORMAL_ADDRESS,
        to: defaultAccount.address,
        value: 0,
        data: defaultAccount.interface.encodeFunctionData("validateTransaction", [txHash, signedHash, txData]),
      };
      expect(await bootloader.provider.call(call)).to.be.eq(
        defaultAccount.interface.getSighash("validateTransaction") + "0".repeat(56)
      );
    });
  });

  describe("executeTransaction", function () {
    it("non-deployer ignored", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: callable.address,
        from: account.address,
        nonce: nonce,
        data: "0xdeadbeef",
        value: 5,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      await expect(await defaultAccount.executeTransaction(txHash, signedHash, txData)).to.not.emit(callable, "Called");
    });

    it("successfully executed", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: callable.address,
        from: account.address,
        nonce: nonce,
        data: "0xdeadbeef",
        value: 5,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      await expect(await defaultAccount.connect(bootloader).executeTransaction(txHash, signedHash, txData))
        .to.emit(callable, "Called")
        .withArgs(5, "0xdeadbeef");
    });
  });

  describe("executeTransactionFromOutside", function () {
    it("nothing", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: callable.address,
        from: account.address,
        nonce: nonce,
        data: "0xdeadbeef",
        value: 5,
        gasLimit: 50000,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      delete legacyTx.from;

      await expect(await defaultAccount.executeTransactionFromOutside(txData)).to.not.emit(callable, "Called");
    });
  });

  describe("payForTransaction", function () {
    it("non-deployer ignored", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: callable.address,
        from: account.address,
        nonce: nonce,
        data: "0xdeadbeef",
        value: 5,
        gasLimit: 50000,
        gasPrice: 200,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      const balanceBefore = await l2EthToken.balanceOf(defaultAccount.address);
      await defaultAccount.payForTransaction(txHash, signedHash, txData);
      const balanceAfter = await l2EthToken.balanceOf(defaultAccount.address);
      expect(balanceAfter).to.be.eq(balanceBefore);
    });

    it("successfully payed", async () => {
      const nonce = await nonceHolder.getMinNonce(account.address);
      const legacyTx = await account.populateTransaction({
        type: 0,
        to: callable.address,
        from: account.address,
        nonce: nonce,
        data: "0xdeadbeef",
        value: 5,
        gasLimit: 50000,
        gasPrice: 200,
      });
      const txBytes = await account.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const txHash = parsedTx.hash;
      delete legacyTx.from;
      const signedHash = ethers.utils.keccak256(serialize(legacyTx));

      await expect(await defaultAccount.connect(bootloader).payForTransaction(txHash, signedHash, txData))
        .to.emit(l2EthToken, "Transfer")
        .withArgs(account.address, BOOTLOADER_FORMAL_ADDRESS, 50000 * 200);
    });
  });

  describe("prepareForPaymaster", function () {
    it("non-deployer ignored", async () => {
      const eip712Tx = await account.populateTransaction({
        type: 113,
        to: callable.address,
        from: account.address,
        data: "0x",
        value: 0,
        maxFeePerGas: 12000,
        maxPriorityFeePerGas: 100,
        gasLimit: 50000,
        customData: {
          gasPerPubdata: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: {
            paymaster: RANDOM_ADDRESS,
            paymasterInput: paymasterFlowInterface.encodeFunctionData("approvalBased", [
              mockERC20Approve.address,
              2023,
              "0x",
            ]),
          },
        },
      });
      const signedEip712Tx = await account.signTransaction(eip712Tx);
      const parsedEIP712tx = zksync.utils.parseTransaction(signedEip712Tx);

      const eip712TxData = signedTxToTransactionData(parsedEIP712tx)!;
      const eip712TxHash = parsedEIP712tx.hash;
      const eip712SignedHash = zksync.EIP712Signer.getSignedDigest(eip712Tx);

      await expect(await defaultAccount.prepareForPaymaster(eip712TxHash, eip712SignedHash, eip712TxData)).to.not.emit(
        mockERC20Approve,
        "Approved"
      );
    });

    it("successfully prepared", async () => {
      const eip712Tx = await account.populateTransaction({
        type: 113,
        to: callable.address,
        from: account.address,
        data: "0x",
        value: 0,
        maxFeePerGas: 12000,
        maxPriorityFeePerGas: 100,
        gasLimit: 50000,
        customData: {
          gasPerPubdata: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: {
            paymaster: RANDOM_ADDRESS,
            paymasterInput: paymasterFlowInterface.encodeFunctionData("approvalBased", [
              mockERC20Approve.address,
              2023,
              "0x",
            ]),
          },
        },
      });
      const signedEip712Tx = await account.signTransaction(eip712Tx);
      const parsedEIP712tx = zksync.utils.parseTransaction(signedEip712Tx);

      const eip712TxData = signedTxToTransactionData(parsedEIP712tx)!;
      const eip712TxHash = parsedEIP712tx.hash;
      const eip712SignedHash = zksync.EIP712Signer.getSignedDigest(eip712Tx);

      await expect(
        await defaultAccount.connect(bootloader).prepareForPaymaster(eip712TxHash, eip712SignedHash, eip712TxData)
      )
        .to.emit(mockERC20Approve, "Approved")
        .withArgs(RANDOM_ADDRESS, 2023);
    });
  });

  describe("fallback/receive", function () {
    it("zero value", async () => {
      const call = {
        from: wallet.address,
        to: defaultAccount.address,
        value: 0,
        data: "0x872384894899834939049043904390390493434343434344433443433434344234234234",
      };
      expect(await wallet.provider.call(call)).to.be.eq("0x");
    });

    describe("prepareForPaymaster", function () {
      it("non-deployer ignored", async () => {
        const eip712Tx = await account.populateTransaction({
          type: 113,
          to: callable.address,
          from: account.address,
          data: "0x",
          value: 0,
          maxFeePerGas: 12000,
          maxPriorityFeePerGas: 100,
          gasLimit: 50000,
          customData: {
            gasPerPubdata: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
            paymasterParams: {
              paymaster: RANDOM_ADDRESS,
              paymasterInput: paymasterFlowInterface.encodeFunctionData("approvalBased", [
                mockERC20Approve.address,
                2023,
                "0x",
              ]),
            },
          },
        });
        const signedEip712Tx = await account.signTransaction(eip712Tx);
        const parsedEIP712tx = zksync.utils.parseTransaction(signedEip712Tx);

        const eip712TxData = signedTxToTransactionData(parsedEIP712tx)!;
        const eip712TxHash = parsedEIP712tx.hash;
        const eip712SignedHash = zksync.EIP712Signer.getSignedDigest(eip712Tx);

        await expect(
          await defaultAccount.prepareForPaymaster(eip712TxHash, eip712SignedHash, eip712TxData)
        ).to.not.emit(mockERC20Approve, "Approved");
      });

      it("successfully prepared", async () => {
        const eip712Tx = await account.populateTransaction({
          type: 113,
          to: callable.address,
          from: account.address,
          data: "0x",
          value: 0,
          maxFeePerGas: 12000,
          maxPriorityFeePerGas: 100,
          gasLimit: 50000,
          customData: {
            gasPerPubdata: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
            paymasterParams: {
              paymaster: RANDOM_ADDRESS,
              paymasterInput: paymasterFlowInterface.encodeFunctionData("approvalBased", [
                mockERC20Approve.address,
                2023,
                "0x",
              ]),
            },
          },
        });
        const signedEip712Tx = await account.signTransaction(eip712Tx);
        const parsedEIP712tx = zksync.utils.parseTransaction(signedEip712Tx);

        const eip712TxData = signedTxToTransactionData(parsedEIP712tx)!;
        const eip712TxHash = parsedEIP712tx.hash;
        const eip712SignedHash = zksync.EIP712Signer.getSignedDigest(eip712Tx);

        await expect(
          await defaultAccount.connect(bootloader).prepareForPaymaster(eip712TxHash, eip712SignedHash, eip712TxData)
        )
          .to.emit(mockERC20Approve, "Approved")
          .withArgs(RANDOM_ADDRESS, 2023);
      });
    });

    describe("fallback/receive", function () {
      it("zero value by EOA wallet", async () => {
        const call = {
          from: wallet.address,
          to: defaultAccount.address,
          value: 0,
          data: "0x872384894899834939049043904390390493434343434344433443433434344234234234",
        };
        expect(await wallet.provider.call(call)).to.be.eq("0x");
      });

      it("non-zero value by EOA wallet", async () => {
        const call = {
          from: wallet.address,
          to: defaultAccount.address,
          value: 3223,
          data: "0x87238489489983493904904390431212224343434344433443433434344234234234",
        };
        expect(await wallet.provider.call(call)).to.be.eq("0x");
      });

      it("zero value by bootloader", async () => {
        // Here we need to ensure that during delegatecalls even if `msg.sender` is the bootloader,
        // the fallback is behaving correctly
        const calldata = delegateCaller.interface.encodeFunctionData("delegateCall", [defaultAccount.address]);
        const call = {
          from: BOOTLOADER_FORMAL_ADDRESS,
          to: delegateCaller.address,
          value: 0,
          data: calldata,
        };
        expect(await bootloader.call(call)).to.be.eq("0x");
      });

      it("non-zero value by bootloader", async () => {
        // Here we need to ensure that during delegatecalls even if `msg.sender` is the bootloader,
        // the fallback is behaving correctly
        const calldata = delegateCaller.interface.encodeFunctionData("delegateCall", [defaultAccount.address]);
        const call = {
          from: BOOTLOADER_FORMAL_ADDRESS,
          to: delegateCaller.address,
          value: 3223,
          data: calldata,
        };
        expect(await bootloader.call(call)).to.be.eq("0x");
      });
    });
  });
});
