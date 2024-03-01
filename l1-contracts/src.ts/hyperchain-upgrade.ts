// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";

import type { BigNumberish, Wallet } from "ethers";
import { ethers } from "ethers";

import type { FacetCut, DiamondCut } from "./diamondCut";
import {getFacetCutsForUpgrade} from "./diamondCut";

import type { Deployer } from "./deploy";

import { Interface } from "ethers/lib/utils";
import { Diamond, Verifier } from "../typechain";
import { Address } from "zksync-ethers/build/src/types";
import { L2CanonicalTransaction, ProposedUpgrade , VerifierParams, SYSTEM_UPGRADE_L2_TX_TYPE} from "./utils";

export async function upgradeToHyperchains(
    deployer: Deployer,
    gasPrice: BigNumberish,
    create2Salt?: string,
    nonce?: number
) { 
    // does not interfere with existing system
    await deployNewContracts(deployer, gasPrice, create2Salt, nonce);

    // upgrading system contracts on Era only adds setChainId in systemContext, does not interfere with anything
    // we first upgrade the DiamondProxy. the Mailbox is backwards compatible, so the L1ERC20 and other bridges should still work.
    // but this requires the sharedBridge to be deployed. 
    // kl to: (is this needed?) disable shared bridge deposits until L2Bridge is upgraded. 
    await integrateEraIntoBridgehubAndUpgradeL2SystemContract(deployer, gasPrice, create2Salt, nonce);

    // the L2Bridge and L1ERC20Bridge should be updated relatively in sync, as new messages might not be parsed correctly by the old bridge. 
    // however new bridges can parse old messages. L1->L2 messages are faster, so L2 side is upgraded first. 
    // until we integrate Era into the Bridgehub, txs will not work. 
    await upgradeL2Bridge(deployer, gasPrice, create2Salt, nonce);  
    // kl todo add both bridge address to L2Bridge, so that it can receive txs from both bridges
    // kl todo: enable L1SharedBridge deposits if disabled.
    await upgradeL1ERC20Bridge(deployer, gasPrice, create2Salt, nonce);
    // // note, withdrawals will not work until this step, but deposits will
    await migrateBridges(deployer, gasPrice, create2Salt, nonce);
}
  

async function deployNewContracts(
    deployer: Deployer,
    gasPrice: BigNumberish,
    create2Salt?: string,
    nonce?: number
) {

    nonce = nonce || (await deployer.deployWallet.getTransactionCount());
    create2Salt = create2Salt || ethers.utils.hexlify(ethers.utils.randomBytes(32));
  
    // Create2 factory already deployed on the public networks, only deploy it on local node
    // if (process.env.CHAIN_ETH_NETWORK === "localhost" || process.env.CHAIN_ETH_NETWORK === "hardhat") {
    //   await deployer.deployCreate2Factory({ gasPrice, nonce });
    //   nonce++;
  
    //   await deployer.deployMulticall3(create2Salt, { gasPrice, nonce });
    //   nonce++;
    // }

    await deployer.deployGenesisUpgrade(create2Salt, {
        gasPrice,
        nonce,
      });
      nonce++;
    
    await deployer.deployValidatorTimelock(create2Salt, { gasPrice, nonce });
    nonce++;

    // kl todo check if this needs to be deployed
    await deployer.deployDefaultUpgrade(create2Salt, {
        gasPrice,
        nonce,
    });
    nonce++;
    
    await deployer.deployGenesisUpgrade(create2Salt, {
        gasPrice,
        nonce,
    });
    nonce++;

    // kl todo make sure we don't need to deploy governance. 
    
    // kl todo: we will need to deploy the proxyAdmin on mainnet
    // await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
    await deployer.deployBridgehubContract(create2Salt, gasPrice);

    await deployer.deployStateTransitionManagerContract(create2Salt, [], gasPrice);
    await deployer.setStateTransitionManagerInValidatorTimelock({ gasPrice });

    await deployer.deploySharedBridgeContracts(create2Salt, gasPrice);
    await deployer.deployERC20BridgeImplementation(create2Salt, { gasPrice });
}

async function integrateEraIntoBridgehubAndUpgradeL2SystemContract(
    deployer: Deployer,  
    gasPrice: BigNumberish, 
    create2Salt?: string,
    nonce?: number
) {
    // era facet cut
    const defaultUpgrade = new Interface(hardhat.artifacts.readArtifactSync("DefaultUpgrade").abi);
    const verifierParams: VerifierParams = {recursionNodeLevelVkHash: ethers.constants.HashZero , recursionLeafLevelVkHash:  ethers.constants.HashZero, recursionCircuitsSetVksHash: ethers.constants.HashZero };
    const l2ProtocolUpgradeTx : L2CanonicalTransaction = {txType: SYSTEM_UPGRADE_L2_TX_TYPE, from: L2, to: , gasLimit: , gasPerPubdataByteLimit:, maxFeePerGas:, maxPriorityFeePerGas:, paymaster: , nonce: , value: , reserved: , data: , signature: , factoryDeps: , paymasterInput: , reservedDynamic: } ; 
    const proposedUpgrade : ProposedUpgrade = {l2ProtocolUpgradeTx , factoryDeps: , bootloaderHash: , defaultAccountHash: , verifier: , verifierParams: , l1ContractsUpgradeCalldata: , postUpgradeCalldata: , upgradeTimestamp: , newProtocolVersion: };
    const defaultUpgradeData  = defaultUpgrade.encodeFunctionData("upgrade", [proposedUpgrade]);

    const facetCuts = await getFacetCutsForUpgrade(deployer.deployWallet, deployer.addresses.StateTransition.DiamondProxy, deployer.addresses.StateTransition.AdminFacet, deployer.addresses.StateTransition.GettersFacet, deployer.addresses.StateTransition.MailboxFacet, deployer.addresses.StateTransition.ExecutorFacet);
    const diamondCut : DiamondCut = {facetCuts, initAddress: deployer.addresses.StateTransition.DefaultUpgrade, initCalldata: defaultUpgradeData}
    
    const adminFacet = new Interface(hardhat.artifacts.readArtifactSync("IAdmin").abi);
    const data = adminFacet.encodeFunctionData("executeUpgrade2", [diamondCut]); // kl todo calldata might not be "0x"
    
    const call :  {target: string, value: BigNumberish, data: string} = {target : deployer.addresses.StateTransition.DiamondProxy, value : "0", data}
    const predecessor = ethers.constants.HashZero; // kl todo, we might want to have a proper predecessor on mainnet
    const salt = ethers.constants.HashZero;
    
    const operation = {calls: [call], predecessor, salt}
    
    const governanceContract = deployer.governanceContract(deployer.deployWallet);
    await governanceContract.scheduleTransparent(operation, 0);
    await governanceContract.execute(operation);
    // bridgehub set Era
    const bridgehub = deployer.bridgehubContract(deployer.deployWallet);
    // kl todo
    // STM set era diamond
    const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);
    // kl todo
} 

async function upgradeL2Bridge(
    deployer: Deployer, 
    gasPrice: BigNumberish,  
    create2Salt?: string,
    nonce?: number
) {
    // upgrade L2 bridge contract, we do this directly via the L2
    // set initializeChainGovernance in L1SharedBridge
}

async function upgradeL1ERC20Bridge(
    deployer: Deployer,   
    gasPrice: BigNumberish,
    create2Salt?: string,
    nonce?: number
) {
    // upgrade old contracts
    await deployer.upgradeL1ERC20Bridge(true);
}

async function migrateBridges(
    deployer: Deployer,
    gasPrice: BigNumberish,   
    create2Salt?: string,
    nonce?: number
) {
    migrateEthFromMailboxAndChainBalance(deployer, gasPrice, create2Salt, nonce);
    migrateAssetsFromL1ERC20BridgeAndChainBalance(deployer, gasPrice, create2Salt, nonce);
}

async function migrateAssetsFromL1ERC20BridgeAndChainBalance(
    deployer: Deployer,  
    gasPrice: BigNumberish, 
    create2Salt?: string,
    nonce?: number
) {
    // migrate assets from L1 ERC20 bridge
}

async function migrateEthFromMailboxAndChainBalance(
    deployer: Deployer,
    gasPrice: BigNumberish,   
    create2Salt?: string,
    nonce?: number
) {
    // migrate eth from mailbox
}

  