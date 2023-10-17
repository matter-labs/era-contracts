import { expect } from 'chai';
import { BigNumberish, ethers, Wallet } from 'ethers';
import * as hardhat from 'hardhat';

import * as fs from 'fs';

import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from 'zksync-web3/build/src/utils';
import {
    AllowList,
    TestnetERC20Token,
    TestnetERC20TokenFactory,
    BridgehubMailboxFacet,
    BridgehubMailboxFacetFactory
} from '../../typechain';
import { IL1Bridge } from '../../typechain/IL1Bridge';
import { IL1BridgeFactory } from '../../typechain/IL1BridgeFactory';
import { AccessMode, getCallRevertReason } from './utils';

import { Deployer } from '../../src.ts/deploy';

const zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

const L2_BOOTLOADER_BYTECODE_HASH = '0x1000100000000000000000000000000000000000000000000000000000000000';
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = '0x1001000000000000000000000000000000000000000000000000000000000000';

const testConfigPath = './test/test_config/constant';
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: 'utf-8' }));

describe(`L1ERC20Bridge tests`, function () {
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let l1ERC20BridgeAddress: string;
    let l1ERC20Bridge: IL1Bridge;
    let erc20TestToken: TestnetERC20Token;
    let testnetERC20TokenContract: ethers.Contract;
    let l1Erc20BridgeContract: ethers.Contract;
    let bridgehubMailboxFacet: BridgehubMailboxFacet;
    let chainId = 0;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(
            owner.provider
        );
        const ownerAddress = await deployWallet.getAddress();
        process.env.ETH_CLIENT_CHAIN_ID = (await deployWallet.getChainId()).toString();

        const gasPrice = await owner.provider.getGasPrice();

        const tx = {
            from: owner.getAddress(),
            to: deployWallet.address,
            value: ethers.utils.parseEther('1000'),
            nonce: owner.getTransactionCount(),
            gasLimit: 100000,
            gasPrice: gasPrice
        };

        await owner.sendTransaction(tx);

        const deployer = new Deployer({
            deployWallet,
            ownerAddress,
            verbose: false,
            addresses: addressConfig,
            bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
            defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH
        });

        const create2Salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

        let nonce = await deployWallet.getTransactionCount();

        await deployer.deployCreate2Factory({ gasPrice, nonce });
        nonce++;

        // await deployer.deployMulticall3(create2Salt, {gasPrice, nonce});
        // nonce++;

        process.env.CONTRACTS_GENESIS_ROOT = zeroHash;
        process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = '0';
        process.env.CONTRACTS_GENESIS_BLOCK_COMMITMENT = zeroHash;
        process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = '72000000';
        process.env.CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH = zeroHash;

        await deployer.deployAllowList(create2Salt, { gasPrice, nonce });
        await deployer.deployBridgehubContract(create2Salt, gasPrice);
        await deployer.deployStateTransitionContract(create2Salt,null, gasPrice);
        await deployer.deployBridgeContracts(create2Salt, gasPrice);
        await deployer.deployWethBridgeContracts(create2Salt, gasPrice);

        const verifierParams = {
            recursionNodeLevelVkHash: zeroHash,
            recursionLeafLevelVkHash: zeroHash,
            recursionCircuitsSetVksHash: zeroHash
        };
        // const initialDiamondCut = await deployer.initialStateTransitionProxyDiamondCut();

        // const proofSystem = deployer.proofSystemContract(deployWallet);

        // await (await proofSystem.setParams(verifierParams, initialDiamondCut)).wait();

        await deployer.registerHyperchain(create2Salt, null, gasPrice);
        chainId = deployer.chainId;

        // const validatorTx = await deployer.proofChainContract(deployWallet).setValidator(await validator.getAddress(), true);
        // await validatorTx.wait();

        allowList = deployer.l1AllowList(deployWallet);

        const allowTx = await allowList.setBatchAccessMode(
            [
                deployer.addresses.Bridgehub.BridgehubDiamondProxy,
                deployer.addresses.Bridgehub.ChainProxy,
                deployer.addresses.StateTransition.StateTransitionProxy,
                deployer.addresses.StateTransition.DiamondProxy,
                deployer.addresses.Bridges.ERC20BridgeProxy,
                deployer.addresses.Bridges.WethBridgeProxy
            ],
            [
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public
            ]
        );
        await allowTx.wait();

        bridgehubMailboxFacet = BridgehubMailboxFacetFactory.connect(
            deployer.addresses.Bridgehub.BridgehubDiamondProxy,
            deployWallet
        );

        const l1Erc20BridgeFactory = await hardhat.ethers.getContractFactory('L1ERC20Bridge');
        l1Erc20BridgeContract = await l1Erc20BridgeFactory.deploy(
            deployer.addresses.Bridgehub.BridgehubDiamondProxy,
            allowList.address
        );
        l1ERC20BridgeAddress = l1Erc20BridgeContract.address;
        l1ERC20Bridge = IL1BridgeFactory.connect(l1ERC20BridgeAddress, deployWallet);

        const testnetERC20TokenFactory = await hardhat.ethers.getContractFactory('TestnetERC20Token');
        testnetERC20TokenContract = await testnetERC20TokenFactory.deploy('TestToken', 'TT', 18);
        erc20TestToken = TestnetERC20TokenFactory.connect(
            testnetERC20TokenContract.address,
            testnetERC20TokenContract.signer
        );

        await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits('10000', 18));
        await erc20TestToken.connect(randomSigner).approve(l1ERC20BridgeAddress, ethers.utils.parseUnits('10000', 18));

        // // Exposing the methods of IZkSync to the diamond proxy
        // bridgehubMailboxFacet = BridgehubMailboxFacetFactory.connect(diamondProxyContract.address, diamondProxyContract.provider);
    });

    it(`Should not allow an un-whitelisted address to deposit`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .deposit(
                    chainId,
                    await randomSigner.getAddress(),
                    testnetERC20TokenContract.address,
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );
        expect(revertReason).equal(`nr`);

        await (await allowList.setAccessMode(l1ERC20BridgeAddress, AccessMode.Public)).wait();
    });

    it(`Should not allow depositing zero amount`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .deposit(
                    chainId,
                    await randomSigner.getAddress(),
                    testnetERC20TokenContract.address,
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );
        expect(revertReason).equal(`2T`);
    });

    it(`Should deposit successfully`, async () => {
        const depositorAddress = await randomSigner.getAddress();
        await depositERC20(
            l1ERC20Bridge.connect(randomSigner),
            bridgehubMailboxFacet,
            chainId,
            depositorAddress,
            testnetERC20TokenContract.address,
            ethers.utils.parseUnits('800', 18),
            10000000
        );
    });

    it(`Should revert on finalizing a withdrawal with wrong message length`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, '0x', [ethers.constants.HashZero])
        );
        expect(revertReason).equal(`nq`);
    });

    it(`Should revert on finalizing a withdrawal with wrong function signature`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(76), [ethers.constants.HashZero])
        );
        expect(revertReason).equal(`nq`);
    });

    it(`Should revert on finalizing a withdrawal with wrong batch number`, async () => {
        const functionSignature = `0xc87325f1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 10, 0, 0, l2ToL1message, [])
        );
        expect(revertReason).equal(`xx`);
    });

    it(`Should revert on finalizing a withdrawal with wrong length of proof`, async () => {
        const functionSignature = `0xc87325f1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, [])
        );
        expect(revertReason).equal(`xc`);
    });

    it(`Should revert on finalizing a withdrawal with wrong proof`, async () => {
        const functionSignature = `0xc87325f1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .finalizeWithdrawal(chainId, 0, 0, 0, l2ToL1message, Array(9).fill(ethers.constants.HashZero))
        );
        expect(revertReason).equal(`nq`);
    });
});

async function depositERC20(
    bridge: IL1Bridge,
    bridgehubMailboxFacet: BridgehubMailboxFacet,
    chainId: BigNumberish,
    l2Receiver: string,
    l1Token: string,
    amount: ethers.BigNumber,
    l2GasLimit: number,
    l2RefundRecipient = ethers.constants.AddressZero
) {
    const gasPrice = await bridge.provider.getGasPrice();
    const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
    const neededValue = await bridgehubMailboxFacet.l2TransactionBaseCost(
        chainId,
        gasPrice,
        l2GasLimit,
        gasPerPubdata
    );

    await bridge.deposit(
        chainId,
        l2Receiver,
        l1Token,
        amount,
        l2GasLimit,
        REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
        l2RefundRecipient,
        {
            value: neededValue
        }
    );
}
