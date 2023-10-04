import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { Action, facetCut, diamondCut } from '../../src.ts/diamondCut';
import {
    BridgeheadMailbox,
    BridgeheadMailboxFactory,
    BridgeheadFactory,
    BridgeheadChainFactory,
    DiamondInitFactory,
    AllowListFactory,
    AllowList,
    Forwarder,
    ForwarderFactory,
    DiamondCutTestFactory,
    DiamondFactory
} from '../../typechain';

import * as fs from 'fs';
import * as path from 'path';

import {
    DEFAULT_REVERT_REASON,
    getCallRevertReason,
    AccessMode,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    requestExecute,
    requestExecuteDirect
} from './utils';
import { Wallet, BigNumberish, BytesLike } from 'ethers';
import { Address } from 'zksync-web3/build/src/types';

import * as ethers from 'ethers';

import { Deployer } from '../../src.ts/deploy';

const zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: 'utf-8' }));

describe('Mailbox tests', function () {
    let allowList: AllowList;
    let bridgeheadContract: ethers.Contract;
    let bridgeheadChainContract: ethers.Contract;
    let diamondProxyContract: ethers.Contract;
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
    const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
    let forwarder: Forwarder;
    let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(
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
            addresses: addressConfig
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

        bridgeheadContract = BridgeheadFactory.connect(deployer.addresses.Bridgehead.BridgeheadProxy, deployWallet);
        bridgeheadChainContract = BridgeheadChainFactory.connect(
            deployer.addresses.Bridgehead.ChainProxy,
            deployWallet
        );

        const forwarderFactory = await hardhat.ethers.getContractFactory('Forwarder');
        const forwarderContract = await forwarderFactory.deploy();
        forwarder = ForwarderFactory.connect(forwarderContract.address, forwarderContract.signer);
    });

    it('Should accept correctly formatted bytecode', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(1000000),
                [new Uint8Array(32)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal(DEFAULT_REVERT_REASON);
    });

    it('Should not accept bytecode is not chunkable', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(63)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('bl');
    });

    it('Should not accept bytecode of even length in words', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(64)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pr');
    });

    it('Should not accept bytecode that is too long', async () => {
        const revertReason = await getCallRevertReason(
            requestExecuteDirect(
                bridgeheadChainContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [
                    // "+64" to keep the length in words odd and bytecode chunkable
                    new Uint8Array(MAX_CODE_LEN_BYTES + 64)
                ],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pp');
    });

    describe('Deposit and Withdrawal limit functionality', function () {
        const DEPOSIT_LIMIT = ethers.utils.parseEther('10');

        before(async () => {
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, DEPOSIT_LIMIT);
        });

        it('Should not accept depositing more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther('12'),
                    '0x',
                    ethers.BigNumber.from(100000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });

        it('Should accept depositing less than or equal to the deposit limit', async () => {
            const gasPrice = await bridgeheadContract.provider.getGasPrice();
            const l2GasLimit = ethers.BigNumber.from(1000000);
            const l2Cost = await bridgeheadContract.l2TransactionBaseCost(
                chainId,
                gasPrice,
                l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    DEPOSIT_LIMIT.sub(l2Cost),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { gasPrice }
                )
            );

            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });

        it('Should not accept depositing that the accumulation is more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(1),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });
    });

    describe(`Access mode functionality`, function () {
        before(async () => {
            // We still need to set infinite amount of allowed deposit limit in order to ensure that every fee will be accepted
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, ethers.utils.parseEther('2000'));
        });

        it(`Should not allow an un-whitelisted address to call`, async () => {
            await allowList.setAccessMode(bridgeheadChainContract.address, AccessMode.Closed);

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract.connect(randomSigner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(100000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );
            expect(revertReason).equal(`nr2`);
        });

        it(`Should allow the whitelisted address to call`, async () => {
            await allowList.setAccessMode(bridgeheadChainContract.address, AccessMode.SpecialAccessOnly);
            await allowList.setPermissionToCall(
                await owner.getAddress(),
                bridgeheadChainContract.address,
                `0xca0fbd7c`,
                true
            );

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );
            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });
    });

    let callDirectly, callViaForwarder, callViaConstructorForwarder;

    before(async () => {
        const l2GasLimit = ethers.BigNumber.from(10000000);

        callDirectly = async (refundRecipient) => {
            return {
                transaction: await requestExecute(
                    chainId,
                    bridgeheadContract.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    refundRecipient
                ),
                expectedSender: await owner.getAddress()
            };
        };

        const encodeRequest = (refundRecipient) =>
            bridgeheadContract.interface.encodeFunctionData('requestL2Transaction', [
                chainId,
                ethers.constants.AddressZero,
                0,
                '0x',
                l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(32)],
                refundRecipient
            ]);

        let overrides: ethers.PayableOverrides = {};
        overrides.gasPrice = await bridgeheadContract.provider.getGasPrice();
        overrides.value = await bridgeheadContract.l2TransactionBaseCost(
            chainId,
            overrides.gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        overrides.gasLimit = 10000000;

        callViaForwarder = async (refundRecipient) => {
            return {
                transaction: await forwarder.forward(
                    bridgeheadContract.address,
                    encodeRequest(refundRecipient),
                    overrides
                ),
                expectedSender: aliasAddress(forwarder.address)
            };
        };

        callViaConstructorForwarder = async (refundRecipient) => {
            const constructorForwarder = await (
                await hardhat.ethers.getContractFactory('ConstructorForwarder')
            ).deploy(bridgeheadContract.address, encodeRequest(refundRecipient), overrides);

            return {
                transaction: constructorForwarder.deployTransaction,
                expectedSender: aliasAddress(constructorForwarder.address)
            };
        };
    });

    it('Should only alias externally-owned addresses', async () => {
        const indirections = [callDirectly, callViaForwarder, callViaConstructorForwarder];
        const refundRecipients = [
            [bridgeheadContract.address, false],
            [await bridgeheadContract.signer.getAddress(), true]
        ];

        for (const sendTransaction of indirections) {
            for (const [refundRecipient, externallyOwned] of refundRecipients) {
                const result = await sendTransaction(refundRecipient);

                const [event] = (await result.transaction.wait()).logs;
                const parsedEvent = bridgeheadContract.interface.parseLog(event);
                expect(parsedEvent.name).to.equal('NewPriorityRequest');

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
        .add('0x1111000000000000000000000000000000001111')
        .mask(20 * 8);
}
