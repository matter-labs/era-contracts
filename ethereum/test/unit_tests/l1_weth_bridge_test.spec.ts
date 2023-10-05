import { expect } from 'chai';
import { ethers, Wallet } from 'ethers';
import * as hardhat from 'hardhat';

import * as fs from 'fs';

import { IBridgehead } from '../../typechain/IBridgehead';
import { AllowList, L1WethBridge, L1WethBridgeFactory, WETH9, WETH9Factory } from '../../typechain';
import { AccessMode, getCallRevertReason } from './utils';
import { hashL2Bytecode } from '../../scripts/utils';

import { Interface } from 'ethers/lib/utils';
import { Address } from 'zksync-web3/build/src/types';

import { Deployer } from '../../src.ts/deploy';

const zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

const L2_BOOTLOADER_BYTECODE_HASH = '0x1000100000000000000000000000000000000000000000000000000000000000';
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = '0x1001000000000000000000000000000000000000000000000000000000000000';

const testConfigPath = './test/test_config/constant';
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: 'utf-8' }));

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = '0x0000000000000000000000000000000000008006';
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export async function create2DeployFromL1(
    bridgehead: IBridgehead,
    chainId: ethers.BigNumberish,
    walletAddress: Address,
    bytecode: ethers.BytesLike,
    constructor: ethers.BytesLike,
    create2Salt: ethers.BytesLike,
    l2GasLimit: ethers.BigNumberish
) {
    const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync('IContractDeployer').abi);
    const bytecodeHash = hashL2Bytecode(bytecode);
    const calldata = deployerSystemContracts.encodeFunctionData('create2', [create2Salt, bytecodeHash, constructor]);
    const gasPrice = await bridgehead.provider.getGasPrice();
    const expectedCost = await bridgehead.l2TransactionBaseCost(
        chainId,
        gasPrice,
        l2GasLimit,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );

    await bridgehead.requestL2Transaction(
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

describe('WETH Bridge tests', () => {
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let bridgeProxy: L1WethBridge;
    let l1Weth: WETH9;
    let functionSignature = '0x0fdef251';
    let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic4, "m/44'/60'/0'/0/1").connect(
            owner.provider
        );
        const governorAddress = await deployWallet.getAddress();

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
            governorAddress,
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
        await deployer.deployBridgeheadContract(create2Salt, gasPrice);
        await deployer.deployProofSystemContract(create2Salt, gasPrice);
        await deployer.deployBridgeContracts(create2Salt, gasPrice);
        await deployer.deployWethBridgeContracts(create2Salt, gasPrice);

        const verifierParams = {
            recursionNodeLevelVkHash: zeroHash,
            recursionLeafLevelVkHash: zeroHash,
            recursionCircuitsSetVksHash: zeroHash
        };
        const initialDiamondCut = await deployer.initialProofSystemProxyDiamondCut();

        const proofSystem = deployer.proofSystemContract(deployWallet);

        await (await proofSystem.setParams(verifierParams, initialDiamondCut)).wait();

        await deployer.registerHyperchain(create2Salt, gasPrice);
        chainId = deployer.chainId;

        // const validatorTx = await deployer.proofChainContract(deployWallet).setValidator(await validator.getAddress(), true);
        // await validatorTx.wait();

        allowList = deployer.l1AllowList(deployWallet);

        const allowTx = await allowList.setBatchAccessMode(
            [
                deployer.addresses.Bridgehead.BridgeheadProxy,
                deployer.addresses.Bridgehead.ChainProxy,
                deployer.addresses.ProofSystem.ProofSystemProxy,
                deployer.addresses.ProofSystem.DiamondProxy,
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

        // bridgeheadContract = BridgeheadFactory.connect(deployer.addresses.Bridgehead.BridgeheadProxy, deployWallet);

        l1Weth = WETH9Factory.connect(
            (await (await hardhat.ethers.getContractFactory('WETH9')).deploy()).address,
            owner
        );

        // prepare the bridge

        const bridge = await (
            await hardhat.ethers.getContractFactory('L1WethBridge')
        ).deploy(l1Weth.address, deployer.addresses.Bridgehead.BridgeheadProxy, deployer.addresses.AllowList);

        // we don't test L2, so it is ok to give garbage factory deps and L2 address
        const garbageBytecode = '0x1111111111111111111111111111111111111111111111111111111111111111';
        const garbageAddress = '0x71C7656EC7ab88b098defB751B7401B5f6d8976F';

        const bridgeInitData = bridge.interface.encodeFunctionData('initialize', [
            [garbageBytecode, garbageBytecode],
            garbageAddress,
            await owner.getAddress()
        ]);

        const _bridgeProxy = await (
            await hardhat.ethers.getContractFactory('ERC1967Proxy')
        ).deploy(bridge.address, bridgeInitData);

        bridgeProxy = L1WethBridgeFactory.connect(_bridgeProxy.address, _bridgeProxy.signer);
        await bridgeProxy.initializeChain(
            chainId,
            [garbageBytecode, garbageBytecode],
            ethers.constants.WeiPerEther,
            ethers.constants.WeiPerEther,
            { value: ethers.constants.WeiPerEther.mul(2) }
        );
    });

    it('Should not allow an un-whitelisted address to deposit', async () => {
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

        expect(revertReason).equal('nr');

        // This is only so the following tests don't need whitelisting
        await (await allowList.setAccessMode(bridgeProxy.address, AccessMode.Public)).wait();
    });

    it('Should not allow depositing zero WETH', async () => {
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

        expect(revertReason).equal('Amount cannot be zero');
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

    it('Should revert on finalizing a withdrawal with wrong message length', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, '0x', [])
        );
        expect(revertReason).equal('pm');
    });

    it('Should revert on finalizing a withdrawal with wrong function selector', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
        );
        expect(revertReason).equal('is');
    });

    it('Should revert on finalizing a withdrawal with wrong receiver', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy
                .connect(randomSigner)
                .finalizeWithdrawal(
                    chainId,
                    0,
                    0,
                    0,
                    ethers.utils.hexConcat([functionSignature, ethers.utils.randomBytes(92)]),
                    []
                )
        );
        expect(revertReason).equal('rz');
    });

    it('Should revert on finalizing a withdrawal with wrong L2 sender', async () => {
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
                        ethers.utils.randomBytes(40)
                    ]),
                    []
                )
        );
        expect(revertReason).equal('rz');
    });
});
