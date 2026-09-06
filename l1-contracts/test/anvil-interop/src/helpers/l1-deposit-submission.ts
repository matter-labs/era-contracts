import type { BigNumber, BigNumberish, Signer, providers } from "ethers";
import { Contract, ethers } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  DEFAULT_TX_GAS_LIMIT,
  ETH_TOKEN_ADDRESS,
} from "../core/const";
import { encodeAssetRouterDepositData, encodeBridgeBurnData } from "../core/data-encoding";
import { encodeIndirectInteropRequest } from "../core/interop-requests";

interface ERC20DepositSubmission {
  bridgehubAddress: string;
  chainId: number;
  tokenAddress: string;
  amount: BigNumber;
  l2GasLimit: BigNumberish;
  recipient?: string;
  gasPrice?: BigNumberish;
}

/** Submits a non-base ERC20 deposit with the caller's signer and waits for its L1 receipt. */
export async function submitERC20Deposit(
  _signer: Signer,
  _params: ERC20DepositSubmission
): Promise<{ receipt: providers.TransactionReceipt; mintValue: BigNumber; assetId: string }> {
  const caller = await _signer.getAddress();
  const recipient = _params.recipient ?? caller;
  const bridgehub = new Contract(_params.bridgehubAddress, getAbi("L1Bridgehub"), _signer);
  const interopCenter = new Contract(await bridgehub.interopCenter(), getAbi("L1InteropCenter"), _signer);
  const assetRouter = new Contract(await bridgehub.assetRouter(), getAbi("L1AssetRouter"), _signer);
  const vault = new Contract(await assetRouter.nativeTokenVault(), getAbi("L1NativeTokenVault"), _signer);
  const baseTokenAddress: string = await bridgehub.baseToken(_params.chainId);
  if (baseTokenAddress.toLowerCase() === _params.tokenAddress.toLowerCase()) {
    throw new Error("Use a direct request to deposit the destination base token");
  }

  let assetId: string = await vault.assetId(_params.tokenAddress);
  if (assetId === ethers.constants.HashZero) {
    await (await vault.registerToken(_params.tokenAddress)).wait();
    assetId = await vault.assetId(_params.tokenAddress);
  }

  const approve = async (_tokenAddress: string, _amount: BigNumber): Promise<void> => {
    const token = new Contract(_tokenAddress, getAbi("TestnetERC20Token"), _signer);
    if ((await token.allowance(caller, vault.address)).lt(_amount)) {
      await (await token.approve(vault.address, _amount)).wait();
    }
  };
  await approve(_params.tokenAddress, _params.amount);

  const gasPrice = _params.gasPrice ?? (await _signer.getGasPrice());
  const mintValue: BigNumber = await interopCenter.l2TransactionBaseCost(
    _params.chainId,
    gasPrice,
    _params.l2GasLimit,
    ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );
  const baseIsEth = baseTokenAddress.toLowerCase() === ETH_TOKEN_ADDRESS.toLowerCase();
  if (!baseIsEth) {
    await approve(baseTokenAddress, mintValue);
  }

  const message = encodeIndirectInteropRequest({
    chainId: _params.chainId,
    mintValue,
    l2Value: 0,
    l2GasLimit: _params.l2GasLimit,
    l2GasPerPubdataByteLimit: ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    refundRecipient: recipient,
    crossChainSender: assetRouter.address,
    indirectCallValue: 0,
    indirectCallData: encodeAssetRouterDepositData(
      assetId,
      encodeBridgeBurnData(_params.amount, recipient, _params.tokenAddress)
    ),
  });
  const tx = await interopCenter.sendMessage(message.recipient, message.payload, message.attributes, {
    value: baseIsEth ? mintValue : 0,
    gasPrice,
    gasLimit: DEFAULT_TX_GAS_LIMIT,
  });
  return { receipt: await tx.wait(), mintValue, assetId };
}
